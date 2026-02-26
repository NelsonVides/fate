defmodule Fate.Frequency.CountMinSketch do
  @moduledoc """
  Concurrent Count-Min Sketch implementation backed by `:atomics`.

  A Count-Min Sketch is a space-efficient probabilistic data structure for estimating
  the frequency of elements in a data stream. It may **overestimate**, but it never
  underestimates, the true count, with error bounded by configurable parameters.

  ## Features

  - Lock-free concurrent reads and writes via `:atomics`
  - Configurable accuracy via error-bound (`epsilon`/`delta`) or explicit dimensions
  - Arbitrary increment support (`update/3`)
  - Optional top-k heavy hitter tracking via min-heap
  - Serialization/deserialization
  - Merge operation for combining sketches
  - Pluggable hash functions

  ## Examples

      # Create via error bounds: epsilon controls overcount, delta controls probability
      sketch = CountMinSketch.new(epsilon: 0.001, delta: 0.01)

      # Or specify dimensions directly
      sketch = CountMinSketch.new(width: 2048, depth: 5)

      # Insert items
      CountMinSketch.put(sketch, "page:/home")
      CountMinSketch.put(sketch, "page:/home")
      CountMinSketch.put(sketch, "page:/about")

      # Estimate frequency
      CountMinSketch.estimate(sketch, "page:/home")   # => 2 (or slightly more)
      CountMinSketch.estimate(sketch, "page:/about")   # => 1 (or slightly more)
      CountMinSketch.estimate(sketch, "page:/missing") # => 0

      # Increment by arbitrary count
      CountMinSketch.update(sketch, "page:/home", 10)

      # Track top-k heavy hitters
      sketch = CountMinSketch.new(width: 2048, depth: 5, top_k: 10)
      Enum.each(1..1000, fn i -> CountMinSketch.put(sketch, i) end)
      CountMinSketch.top(sketch)  # => [{item, estimate}, ...] top 10 by frequency

      # Serialize for storage
      binary = CountMinSketch.serialize(sketch)
      restored = CountMinSketch.deserialize(binary)

      # Merge multiple sketches
      merged = CountMinSketch.merge([sketch1, sketch2])

  ## When to Use

  Count-Min Sketch is ideal when:
  - You need frequency estimates for a large number of distinct items
  - Memory is constrained (fixed size regardless of item count)
  - Overestimates are acceptable but underestimates are not
  - Concurrent writers are updating counts simultaneously

  Common use cases: network traffic monitoring, NLP word counts, trending topic
  detection, database query frequency analysis.

  ## Error Guarantees

  With parameters `epsilon` and `delta`:
  - The estimate for any item is at most `epsilon * N` above the true count,
    where `N` is the total number of increments across all items
  - This guarantee holds with probability at least `1 - delta`

  ## Heavy Hitter Tracking

  When `:top_k` is provided, the sketch maintains a min-heap of the k items with the
  highest estimated frequencies. This allows efficient "what are the most frequent items?"
  queries without scanning all possible items.

  On merge, the heaps from all input sketches are unioned and re-queried against the
  merged CMS to produce accurate top-k results. Input sketches can track more items
  than the merged output (e.g. each tracks top-200, merged keeps top-50) for better
  candidate coverage.

  ### Concurrency and the heap

  Counter updates use `:atomics` and are safe under concurrent writers. The ETS-backed
  top-k structure is **not** fully synchronized with those updates: admission, eviction,
  size checks, and the cached minimum estimate are separate steps. Under heavy parallel
  `put`/`update` traffic, the heap may briefly hold more than `k` entries, rankings may
  lag, or rare interleavings may produce surprising results. For **strict** top-k
  semantics, serialize updates (e.g. a single writer process) or add your own locking
  around the sketch.

  ### ETS heap lifetime

  The heap table is created with `:ets.new/2` in the **calling process** of `new/1`.
  It is not given an heir. If that process exits, the table is **deleted** and the
  sketch’s `heap` reference becomes invalid. Keep the sketch in a long-lived owner
  (such as a `GenServer`) or treat the structure as tied to that process’s lifetime.

  ## Hash Functions

  The sketch uses seeded hashing to derive independent row indices. Hashing can be
  customised via the `:hash_module` option (see `Fate.Hash`). By default, the module
  selects the first available high-performance backend.

      sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.XXH3)
  """

  alias Fate.Hash

  # Slot 1 of the atomics array caches the current heap minimum estimate.
  # All CMS counter indices are offset by 1 to leave room for it.
  @min_index 1
  @counter_base 2

  @type t :: %__MODULE__{
          atomics: :atomics.atomics_ref(),
          width: pos_integer(),
          depth: pos_integer(),
          hash_module: module(),
          top_k: pos_integer() | nil,
          heap: :ets.tid() | nil
        }

  defstruct [
    :atomics,
    :width,
    :depth,
    :hash_module,
    :top_k,
    :heap
  ]

  @doc """
  Creates a new Count-Min Sketch.

  ## Options (error-bound mode)

    * `:epsilon` – maximum overestimate as a fraction of total count (e.g. `0.001`).
    * `:delta` – probability that the error exceeds the epsilon bound (e.g. `0.01`).

  ## Options (explicit mode)

    * `:width` – number of columns (counters per row).
    * `:depth` – number of rows (independent hash functions).

  ## Common options

    * `:hash_module` – module implementing `Fate.Hash` (auto-selected when omitted).
    * `:top_k` – when set to a positive integer, enables heavy hitter tracking
      with a min-heap of at most `top_k` items. The heap is a private ETS table owned
      by the calling process; see module documentation on lifetime and concurrency.

  You must provide either `epsilon`/`delta` or `width`/`depth`, but not both.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    {width, depth} = resolve_dimensions!(opts)
    hash_module = Keyword.get(opts, :hash_module, Hash.module())
    top_k = Keyword.get(opts, :top_k)

    unless Hash.available?(hash_module) do
      raise ArgumentError, "hash module #{inspect(hash_module)} is not available"
    end

    if top_k != nil do
      unless is_integer(top_k) and top_k > 0 do
        raise ArgumentError, "top_k must be a positive integer"
      end
    end

    size = width * depth
    atomics = :atomics.new(size + 1, signed: false)

    heap =
      if top_k do
        :ets.new(:fate_cms_heap, ets_opts())
      end

    %__MODULE__{
      atomics: atomics,
      width: width,
      depth: depth,
      hash_module: hash_module,
      top_k: top_k,
      heap: heap
    }
  end

  @doc """
  Increments the count for `item` by 1.
  """
  @spec put(t(), term()) :: :ok
  def put(%__MODULE__{heap: nil} = sketch, item) do
    do_update(sketch, item, 1, 0)
  end

  def put(%__MODULE__{} = sketch, item) do
    est = do_update_estimate(sketch, item, 1, 0, :infinity)
    maybe_update_heap(sketch, item, est)
  end

  @doc """
  Increments the count for `item` by `count`.
  """
  @spec update(t(), term(), pos_integer()) :: :ok
  def update(%__MODULE__{heap: nil} = sketch, item, count)
      when is_integer(count) and count > 0 do
    do_update(sketch, item, count, 0)
  end

  def update(%__MODULE__{} = sketch, item, count) when is_integer(count) and count > 0 do
    est = do_update_estimate(sketch, item, count, 0, :infinity)
    maybe_update_heap(sketch, item, est)
  end

  @doc """
  Returns the estimated frequency of `item`.

  The result is always >= the true count and at most `epsilon * N` above it
  (with probability `1 - delta`), where `N` is the total number of increments.
  """
  @spec estimate(t(), term()) :: non_neg_integer()
  def estimate(%__MODULE__{} = sketch, item) do
    do_estimate(sketch, item, 0, :infinity)
  end

  @doc """
  Returns the current heavy hitters as `[{item, estimate}]` sorted descending by estimate.

  Returns `[]` if top-k tracking is not enabled.
  """
  @spec top(t()) :: [{term(), non_neg_integer()}]
  def top(%__MODULE__{heap: nil}), do: []

  def top(%__MODULE__{heap: heap}) do
    heap
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_item, est} -> est end, :desc)
  end

  @doc """
  Returns `true` if `item` is currently tracked as a heavy hitter.

  Always returns `false` if top-k tracking is not enabled.
  """
  @spec heavy_hitter?(t(), term()) :: boolean()
  def heavy_hitter?(%__MODULE__{heap: nil}, _item), do: false

  def heavy_hitter?(%__MODULE__{heap: heap}, item) do
    :ets.member(heap, item)
  end

  @doc """
  Merges multiple sketches with identical CMS configuration by summing counters.

  All sketches must share the same `width`, `depth`, and `hash_module`.

  ## Options

    * `:top_k` – size of the output heap. Defaults to the first sketch's `top_k`.
      Input sketches can have larger heaps for better candidate coverage.

  When any input sketch has a heap, the merge unions all tracked items, re-queries
  the merged CMS for each, and keeps the top-k by estimate.
  """
  @spec merge([t(), ...], keyword()) :: t()
  def merge(sketches, opts \\ [])

  def merge([first | rest], opts) do
    ensure_compatible!(rest, first)

    # Merge CMS counters
    output_top_k = Keyword.get(opts, :top_k, first.top_k)
    merged = empty_like(first, top_k: output_top_k)
    size = first.width * first.depth

    Enum.each(@counter_base..(size + 1), fn idx ->
      value =
        Enum.reduce(rest, :atomics.get(first.atomics, idx), fn sketch, acc ->
          acc + :atomics.get(sketch.atomics, idx)
        end)

      :atomics.put(merged.atomics, idx, value)
    end)

    # Merge heaps: union all candidates, re-query merged CMS, keep top-k
    if merged.heap do
      candidates =
        [first | rest]
        |> Enum.flat_map(fn sketch ->
          if sketch.heap, do: :ets.tab2list(sketch.heap), else: []
        end)
        |> Enum.uniq_by(fn {item, _est} -> item end)
        |> Enum.map(fn {item, _est} -> {item, estimate(merged, item)} end)
        |> Enum.sort_by(fn {_item, est} -> est end, :desc)
        |> Enum.take(merged.top_k)

      Enum.each(candidates, fn entry -> :ets.insert(merged.heap, entry) end)

      if length(candidates) > 0 do
        refresh_cached_min(merged.atomics, merged.heap)
      end
    end

    merged
  end

  @doc """
  Returns a new sketch with the same configuration but all counters reset to zero.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = sketch) do
    empty_like(sketch)
  end

  @doc """
  Serialises the sketch into a binary for storage/transmission.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = sketch) do
    size = sketch.width * sketch.depth

    data = %{
      width: sketch.width,
      depth: sketch.depth,
      hash_module: sketch.hash_module,
      counters: Enum.map(@counter_base..(size + 1), &:atomics.get(sketch.atomics, &1)),
      top_k: sketch.top_k,
      heap_entries: if(sketch.heap, do: :ets.tab2list(sketch.heap), else: [])
    }

    :erlang.term_to_binary({:fate_count_min_sketch, data})
  end

  @doc """
  Deserialises a sketch that was previously `serialize/1`d.
  """
  @spec deserialize(binary()) :: t()
  def deserialize(binary) when is_binary(binary) do
    {:fate_count_min_sketch, data} = :erlang.binary_to_term(binary)
    do_deserialize(data)
  end

  # -- Private ----------------------------------------------------------------

  defp do_deserialize(data) do
    size = data.width * data.depth
    atomics = :atomics.new(size + 1, signed: false)

    Enum.with_index(data.counters, @counter_base)
    |> Enum.each(fn {value, idx} -> :atomics.put(atomics, idx, value) end)

    heap =
      if data.top_k do
        table = :ets.new(:fate_cms_heap, ets_opts())
        Enum.each(data.heap_entries, fn entry -> :ets.insert(table, entry) end)
        table
      end

    if heap && data.heap_entries != [] do
      refresh_cached_min(atomics, heap)
    end

    %__MODULE__{
      atomics: atomics,
      width: data.width,
      depth: data.depth,
      hash_module: data.hash_module,
      top_k: data.top_k,
      heap: heap
    }
  end

  defp ets_opts do
    [:set, :public, write_concurrency: :auto]
  end

  defp resolve_dimensions!(opts) do
    has_error_bound = Keyword.has_key?(opts, :epsilon) or Keyword.has_key?(opts, :delta)
    has_explicit = Keyword.has_key?(opts, :width) or Keyword.has_key?(opts, :depth)

    cond do
      has_error_bound and has_explicit ->
        raise ArgumentError,
              "provide either :epsilon/:delta or :width/:depth, not both"

      has_error_bound ->
        epsilon = Keyword.fetch!(opts, :epsilon)
        delta = Keyword.fetch!(opts, :delta)
        validate_error_bounds!(epsilon, delta)
        width = :math.ceil(:math.exp(1) / epsilon) |> trunc()
        depth = :math.ceil(:math.log(1 / delta)) |> trunc()
        {max(width, 1), max(depth, 1)}

      has_explicit ->
        width = Keyword.fetch!(opts, :width)
        depth = Keyword.fetch!(opts, :depth)
        validate_dimensions!(width, depth)
        {width, depth}

      true ->
        raise ArgumentError,
              "must provide either :epsilon/:delta or :width/:depth options"
    end
  end

  defp validate_error_bounds!(epsilon, delta) do
    unless is_number(epsilon) and epsilon > 0 and epsilon < 1 do
      raise ArgumentError, "epsilon must be a number between 0 and 1 (exclusive)"
    end

    unless is_number(delta) and delta > 0 and delta < 1 do
      raise ArgumentError, "delta must be a number between 0 and 1 (exclusive)"
    end
  end

  defp validate_dimensions!(width, depth) do
    unless is_integer(width) and width > 0 do
      raise ArgumentError, "width must be a positive integer"
    end

    unless is_integer(depth) and depth > 0 do
      raise ArgumentError, "depth must be a positive integer"
    end
  end

  # Fire-and-forget update: only increments counters, no read-back.
  # Used when heap is disabled and we don't need the estimate.
  defp do_update(%__MODULE__{depth: d}, _item, _count, row) when row >= d, do: :ok

  defp do_update(%__MODULE__{} = sketch, item, count, row) do
    col = Integer.mod(sketch.hash_module.hash(item, row), sketch.width)
    idx = row * sketch.width + col + @counter_base
    :atomics.add(sketch.atomics, idx, count)
    do_update(sketch, item, count, row + 1)
  end

  # Fused update + estimate: increments counters and returns the minimum
  # (post-increment) value across all rows in a single pass.
  defp do_update_estimate(%__MODULE__{depth: d}, _item, _count, row, min) when row >= d, do: min

  defp do_update_estimate(%__MODULE__{} = sketch, item, count, row, min) do
    col = Integer.mod(sketch.hash_module.hash(item, row), sketch.width)
    idx = row * sketch.width + col + @counter_base
    value = :atomics.add_get(sketch.atomics, idx, count)
    do_update_estimate(sketch, item, count, row + 1, min(value, min))
  end

  # Read-only estimate loop — used by estimate/2 and merge
  defp do_estimate(%__MODULE__{depth: d}, _item, row, min) when row >= d, do: min

  defp do_estimate(%__MODULE__{} = sketch, item, row, min) do
    col = Integer.mod(sketch.hash_module.hash(item, row), sketch.width)
    idx = row * sketch.width + col + @counter_base
    value = :atomics.get(sketch.atomics, idx)
    do_estimate(sketch, item, row + 1, min(value, min))
  end

  defp maybe_update_heap(%__MODULE__{heap: nil}, _item, _est), do: :ok

  defp maybe_update_heap(%__MODULE__{heap: heap, top_k: top_k, atomics: ref}, item, est) do
    case :ets.update_element(heap, item, {2, est}) do
      true ->
        refresh_cached_min(ref, heap)

      false ->
        heap_size = :ets.info(heap, :size)

        if top_k <= heap_size do
          # O(1) rejection: skip if estimate doesn't beat cached min
          cached_min = :atomics.get(ref, @min_index)

          if est > cached_min do
            # Single scan: find min to evict and second-min for the new cache.
            # O(k), but rare once the heap stabilises.
            {min_item, _min_est, second_min_est} = scan_heap_min_and_second(heap)
            :ets.delete(heap, min_item)
            :ets.insert(heap, {item, est})
            :atomics.put(ref, @min_index, min(est, second_min_est))
          end
        else
          :ets.insert(heap, {item, est})

          # Heap just became full — seed the cached min
          if heap_size + 1 == top_k do
            refresh_cached_min(ref, heap)
          end
        end
    end

    :ok
  end

  # Single-pass scan returning {min_item, min_est, second_min_est}.
  # second_min_est is the smallest estimate among all entries *except* the min,
  # allowing the caller to compute the new cached min after eviction without
  # a second scan.
  #
  # We walk the table with :ets.first/:ets.next so each {key, estimate} is visited
  # exactly once. Using :ets.foldl/3 with a seeded accumulator would visit the first
  # row twice and could set second_min to the global minimum.
  defp scan_heap_min_and_second(heap) do
    case :ets.first(heap) do
      :"$end_of_table" ->
        raise ArgumentError, "CountMinSketch heap scan requires a non-empty ETS table"

      first_key ->
        first_est = :ets.lookup_element(heap, first_key, 2)

        scan_heap_min_and_second_next(
          heap,
          :ets.next(heap, first_key),
          first_key,
          first_est,
          :infinity
        )
    end
  end

  defp scan_heap_min_and_second_next(_heap, :"$end_of_table", min_item, min_est, second_min) do
    {min_item, min_est, second_min}
  end

  defp scan_heap_min_and_second_next(heap, key, min_item, min_est, second_min) do
    est = :ets.lookup_element(heap, key, 2)

    {next_min_item, next_min_est, next_second} =
      cond do
        est < min_est -> {key, est, min_est}
        est < second_min -> {min_item, min_est, est}
        true -> {min_item, min_est, second_min}
      end

    scan_heap_min_and_second_next(
      heap,
      :ets.next(heap, key),
      next_min_item,
      next_min_est,
      next_second
    )
  end

  defp refresh_cached_min(ref, heap) do
    {_item, min_est, _second} = scan_heap_min_and_second(heap)
    :atomics.put(ref, @min_index, min_est)
  end

  defp empty_like(%__MODULE__{} = sketch, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, sketch.top_k)
    new(width: sketch.width, depth: sketch.depth, hash_module: sketch.hash_module, top_k: top_k)
  end

  defp ensure_compatible!(sketches, reference) do
    Enum.each(sketches, fn sketch ->
      unless sketch.width == reference.width and
               sketch.depth == reference.depth and
               sketch.hash_module == reference.hash_module do
        raise ArgumentError, "sketches must share width, depth, and hash module"
      end
    end)
  end
end
