defmodule Fate.Filter.Cuckoo do
  @moduledoc """
  Concurrent-friendly Cuckoo filter backed by `:atomics`.

  A Cuckoo filter is a compact probabilistic data structure for set membership testing
  with support for **deletions**, making it more versatile than Bloom filters while
  maintaining similar space efficiency.

  ## Features

  - Lock-free concurrent operations via `:atomics`
  - Item deletion support (unlike Bloom filters)
  - Bounded false-positive rate
  - Configurable bucket size and fingerprint bits
  - Exact item count tracking
  - Serialization/deserialization
  - Set operations (merge, intersection)
  - Statistics and analytics
  - Pluggable hash functions

  ## Performance

  This implementation matches the performance of the Erlang reference implementation
  when using the same hash function, using bitpacked bucket storage, eviction caching,
  and optimized relocation strategies.

  ## Examples

      # Create a filter for 1000 items
      cuckoo = Cuckoo.new(1000)

      # Insert items
      :ok = Cuckoo.put(cuckoo, "session:abc")
      :ok = Cuckoo.put(cuckoo, "session:def")

      # Check membership
      Cuckoo.member?(cuckoo, "session:abc")  # => true
      Cuckoo.member?(cuckoo, "session:xyz")  # => false

      # Delete items (unique to Cuckoo filters!)
      :ok = Cuckoo.delete(cuckoo, "session:abc")
      Cuckoo.member?(cuckoo, "session:abc")  # => false

      # Check capacity and load
      Cuckoo.size(cuckoo)         # => 1
      Cuckoo.capacity(cuckoo)     # => 1000
      Cuckoo.load_factor(cuckoo)  # => 0.0002...

      # Handle full filter
      case Cuckoo.put(cuckoo, item) do
        :ok -> :inserted
        {:error, :full} -> :filter_full
      end

      # Get statistics
      Cuckoo.bits_info(cuckoo)              # => %{total_slots: ..., occupied_slots: ..., ...}
      Cuckoo.cardinality(cuckoo)            # => 1 (same as size for Cuckoo)
      Cuckoo.false_positive_probability(cuckoo)  # => ~0.0001

      # Serialize for storage
      binary = Cuckoo.serialize(cuckoo)
      restored = Cuckoo.deserialize(binary)

      # Merge multiple filters
      merged = Cuckoo.merge([cuckoo1, cuckoo2])

  ## When to Use

  Cuckoo filters are ideal when:
  - You need to delete items
  - You want bounded false-positive rates
  - You need exact item counts
  - Slightly higher memory usage than Bloom is acceptable

  ## Configuration

      # Custom configuration
      cuckoo = Cuckoo.new(10_000,
        bucket_size: 4,          # Slots per bucket (default: 4)
        fingerprint_bits: 16,    # Bits per fingerprint (default: 16)
        load_factor: 0.95,       # Target load (default: 0.95)
        max_kicks: 100,          # Max relocations (default: 100)
        hash_module: Fate.Hash.Default
      )

  ## Algorithm

  This implementation closely follows the algorithm from the Erlang `cuckoo_filter`
  reference implementation, using bitpacked bucket storage and eviction caching
  for optimal performance. When both candidate buckets are full, the filter performs
  bounded relocation (cuckoo hashing) to make space.

  ## Hash Functions

  Hashing behaviour is customisable via the `:hash_module` option (see `Fate.Hash`).
  For best performance with simple types (integers, atoms), use `Fate.Hash.Default`
  (`:erlang.phash2`). For complex types or when you need consistent hashing across
  languages, use `Fate.Hash.XXH3` or `Fate.Hash.Murmur3`.

      # Use phash2 for best performance with integers
      cuckoo = Cuckoo.new(1000, hash_module: Fate.Hash.Default)

      # Use XXH3 for complex types
      cuckoo = Cuckoo.new(1000, hash_module: Fate.Hash.XXH3)
  """

  import Bitwise

  alias Fate.Hash

  @type t :: %__MODULE__{
          atomics: :atomics.atomics_ref(),
          bucket_count: pos_integer(),
          bucket_size: pos_integer(),
          fingerprint_bits: pos_integer(),
          fingerprint_mask: non_neg_integer(),
          max_kicks: pos_integer(),
          hash_module: module(),
          capacity: pos_integer()
        }

  defstruct [
    :atomics,
    :bucket_count,
    :bucket_size,
    :fingerprint_bits,
    :fingerprint_mask,
    :max_kicks,
    :hash_module,
    :capacity
  ]

  @default_bucket_size 4
  @default_fingerprint_bits 16
  @default_load_factor 0.95
  @default_max_kicks 100

  # Counter stored at atomics index 3 (matching Erlang reference)
  @counter_index 3

  @doc """
  Creates a new Cuckoo filter sized for the desired `capacity`.

  ## Options

    * `:bucket_size` – slots per bucket (defaults to #{@default_bucket_size}).
    * `:fingerprint_bits` – bits per fingerprint (defaults to #{@default_fingerprint_bits}).
    * `:load_factor` – target load factor before insert failures (defaults to #{@default_load_factor}).
    * `:max_kicks` – maximum relocation attempts before reporting `{:error, :full}`.
    * `:hash_module` – module implementing `Fate.Hash`.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(capacity, opts \\ []) when capacity > 0 do
    bucket_size = Keyword.get(opts, :bucket_size, @default_bucket_size) |> validate_bucket_size!()

    fingerprint_bits =
      Keyword.get(opts, :fingerprint_bits, @default_fingerprint_bits)
      |> validate_fingerprint_bits!()

    load_factor =
      opts |> Keyword.get(:load_factor, @default_load_factor) |> validate_load_factor!()

    max_kicks = Keyword.get(opts, :max_kicks, @default_max_kicks)
    hash_module = Keyword.get(opts, :hash_module, Hash.module())

    unless Hash.available?(hash_module) do
      raise ArgumentError, "hash module #{inspect(hash_module)} is not available"
    end

    # Calculate bucket count as power of 2 (matching Erlang: 1 bsl ceil(math:log2(ceil(Capacity / BucketSize))))
    bucket_count =
      capacity
      |> required_bucket_count(bucket_size, load_factor)
      |> next_power_of_two()

    # Calculate atomics size matching Erlang: ceil(NumBuckets * BucketSize * FingerprintSize / 64) + 3
    bucket_bit_size = bucket_count * bucket_size * fingerprint_bits
    atomics_size = div(bucket_bit_size + 63, 64) + 3
    atomics = :atomics.new(atomics_size, signed: false)

    %__MODULE__{
      atomics: atomics,
      bucket_count: bucket_count,
      bucket_size: bucket_size,
      fingerprint_bits: fingerprint_bits,
      fingerprint_mask: (1 <<< fingerprint_bits) - 1,
      max_kicks: max_kicks,
      hash_module: hash_module,
      capacity: capacity
    }
  end

  @doc """
  Inserts `item` into the filter. Returns `:ok` or `{:error, :full}`.

  Duplicate inserts are treated as no-ops and return `:ok`.
  """
  @spec put(t(), term()) :: :ok | {:error, :full}
  def put(%__MODULE__{} = filter, item) do
    hash = Hash.hash(filter.hash_module, item, 0)
    {index, fingerprint} = index_and_fingerprint(hash, filter)

    case insert_at_index(filter, index, fingerprint) do
      :ok ->
        :ok

      {:error, :full} ->
        alt_index = alt_index(index, fingerprint, filter)

        case insert_at_index(filter, alt_index, fingerprint) do
          :ok ->
            :ok

          {:error, :full} ->
            try_insert(filter, index, fingerprint, :rand.seed_s(:exsss))
        end
    end
  end

  @doc """
  Checks whether `item` may be present in the filter.
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = filter, item) do
    hash = Hash.hash(filter.hash_module, item, 0)
    {index, fingerprint} = index_and_fingerprint(hash, filter)
    alt_index = alt_index(index, fingerprint, filter)

    contains_fingerprint(filter, index, fingerprint) or
      contains_fingerprint(filter, alt_index, fingerprint)
  end

  @doc """
  Deletes `item` from the filter.

  Returns `:ok` if a matching fingerprint is removed, `:not_found` otherwise.
  """
  @spec delete(t(), term()) :: :ok | :not_found
  def delete(%__MODULE__{} = filter, item) do
    hash = Hash.hash(filter.hash_module, item, 0)
    {index, fingerprint} = index_and_fingerprint(hash, filter)
    alt_index = alt_index(index, fingerprint, filter)

    cond do
      delete_fingerprint(filter, index, fingerprint) -> :ok
      delete_fingerprint(filter, alt_index, fingerprint) -> :ok
      true -> :not_found
    end
  end

  @doc """
  Returns the approximate number of items currently stored.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = filter) do
    :atomics.get(filter.atomics, @counter_index)
  end

  @doc """
  Maximum number of (ideal) items the filter was sized for.
  """
  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{} = filter), do: filter.capacity

  @doc """
  Current load factor (0.0–1.0) of occupied slots.
  """
  @spec load_factor(t()) :: float()
  def load_factor(%__MODULE__{} = filter) do
    slots = filter.bucket_count * filter.bucket_size
    size(filter) / slots
  end

  @doc """
  Returns statistics about the current filter state.
  """
  @spec bits_info(t()) :: %{
          total_slots: pos_integer(),
          occupied_slots: non_neg_integer(),
          load_ratio: float(),
          total_bits: pos_integer()
        }
  def bits_info(%__MODULE__{} = filter) do
    occupied_slots = size(filter)
    total_slots = filter.bucket_count * filter.bucket_size
    load_ratio = if total_slots == 0, do: 0.0, else: occupied_slots / total_slots
    total_bits = filter.bucket_count * filter.bucket_size * filter.fingerprint_bits

    %{
      total_slots: total_slots,
      occupied_slots: occupied_slots,
      load_ratio: load_ratio,
      total_bits: total_bits
    }
  end

  @doc """
  Estimates the number of unique elements inserted into the filter.

  For Cuckoo filters, this is the same as `size/1` since we track exact counts.
  This function is provided for API compatibility with Bloom filters.
  """
  @spec cardinality(t()) :: non_neg_integer()
  def cardinality(%__MODULE__{} = filter), do: size(filter)

  @doc """
  Estimates the current false-positive probability.

  For Cuckoo filters, the false positive rate depends on fingerprint size
  and load factor. The formula is approximately: (2 * bucket_size * load_factor) / (2^fingerprint_bits)
  """
  @spec false_positive_probability(t()) :: float()
  def false_positive_probability(%__MODULE__{} = filter) do
    load = load_factor(filter)
    # Approximate FPP: probability of fingerprint collision
    # More accurate: 2 * bucket_size * load / (2^fingerprint_bits)
    max_fingerprint = (1 <<< filter.fingerprint_bits) - 1
    # Simplified approximation based on load and fingerprint space
    approx_fpp = 2.0 * filter.bucket_size * load / max_fingerprint
    min(approx_fpp, 1.0)
  end

  @doc """
  Serialises the filter into a binary for storage/transmission.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = filter) do
    # Calculate atomics size from bucket configuration (avoiding :atomics.info call)
    bucket_bit_size = filter.bucket_count * filter.bucket_size * filter.fingerprint_bits
    atomics_size = div(bucket_bit_size + 63, 64) + 3
    words = Enum.map(1..atomics_size, &:atomics.get(filter.atomics, &1))

    data = %{
      bucket_count: filter.bucket_count,
      bucket_size: filter.bucket_size,
      fingerprint_bits: filter.fingerprint_bits,
      fingerprint_mask: filter.fingerprint_mask,
      max_kicks: filter.max_kicks,
      hash_module: filter.hash_module,
      capacity: filter.capacity,
      words: words
    }

    :erlang.term_to_binary({:fate_cuckoo, 1, data})
  end

  @doc """
  Deserialises a filter that was previously `serialize/1`d.
  """
  @spec deserialize(binary()) :: t()
  def deserialize(binary) when is_binary(binary) do
    {:fate_cuckoo, 1, data} = :erlang.binary_to_term(binary)
    atomics = :atomics.new(length(data.words), signed: false)

    Enum.with_index(data.words, 1)
    |> Enum.each(fn {word, idx} -> :atomics.put(atomics, idx, word) end)

    %__MODULE__{
      atomics: atomics,
      bucket_count: data.bucket_count,
      bucket_size: data.bucket_size,
      fingerprint_bits: data.fingerprint_bits,
      fingerprint_mask: data.fingerprint_mask,
      max_kicks: data.max_kicks,
      hash_module: data.hash_module,
      capacity: data.capacity
    }
  end

  @doc """
  Merges multiple filters with identical configuration.

  Merging Cuckoo filters combines fingerprints from all filters using bitwise OR
  on the atomic words. The counter is recalculated based on occupied slots.
  """
  @spec merge([t(), ...]) :: t()
  def merge([first | rest]) do
    ensure_compatible!(rest, first)

    merged = empty_like(first)
    # Calculate atomics size from bucket configuration (avoiding :atomics.info call)
    bucket_bit_size = first.bucket_count * first.bucket_size * first.fingerprint_bits
    atomics_size = div(bucket_bit_size + 63, 64) + 3

    # Merge atomic words using bitwise OR
    1..atomics_size
    |> Enum.each(fn idx ->
      value =
        Enum.reduce(rest, :atomics.get(first.atomics, idx), fn filter, acc ->
          acc ||| :atomics.get(filter.atomics, idx)
        end)

      :atomics.put(merged.atomics, idx, value)
    end)

    # Recalculate counter based on occupied slots
    recalculate_counter(merged)
    merged
  end

  @doc """
  Intersects multiple filters with identical configuration using bitwise AND.

  Intersection finds fingerprints that are present in all filters.
  The counter is recalculated based on occupied slots.
  """
  @spec intersection([t(), ...]) :: t()
  def intersection([first | rest]) do
    ensure_compatible!(rest, first)

    intersected = empty_like(first)
    # Calculate atomics size from bucket configuration (avoiding :atomics.info call)
    bucket_bit_size = first.bucket_count * first.bucket_size * first.fingerprint_bits
    atomics_size = div(bucket_bit_size + 63, 64) + 3

    # Intersect atomic words using bitwise AND
    1..atomics_size
    |> Enum.each(fn idx ->
      value =
        Enum.reduce(rest, :atomics.get(first.atomics, idx), fn filter, acc ->
          acc &&& :atomics.get(filter.atomics, idx)
        end)

      :atomics.put(intersected.atomics, idx, value)
    end)

    # Recalculate counter based on occupied slots
    recalculate_counter(intersected)
    intersected
  end

  # Matching Erlang index_and_fingerprint/2
  defp index_and_fingerprint(hash, filter) do
    fingerprint = rem(hash, (1 <<< filter.fingerprint_bits) - 1) + 1
    index = hash >>> filter.fingerprint_bits
    {band(index, filter.bucket_count - 1), fingerprint}
  end

  # Matching Erlang alt_index/4
  defp alt_index(index, fingerprint, filter) do
    mix = Hash.hash(filter.hash_module, fingerprint, 1)
    band(bxor(index, mix), filter.bucket_count - 1)
  end

  # Matching Erlang atomic_index/1 - BitIndex bsr 6 + 4
  defp atomic_index(bit_index) do
    (bit_index >>> 6) + 4
  end

  # Matching Erlang read_bucket/2
  defp read_bucket(index, filter) do
    bucket_bit_size = filter.bucket_size * filter.fingerprint_bits
    bit_index = index * bucket_bit_size
    atomic_idx = atomic_index(bit_index)
    skip_bits = band(bit_index, 63)
    end_idx = atomic_index(bit_index + bucket_bit_size - 1)

    # Read consecutive atomic words
    binary =
      atomic_idx..end_idx
      |> Enum.map(fn i -> :atomics.get(filter.atomics, i) end)
      |> Enum.map(&<<&1::64-big-unsigned-integer>>)
      |> IO.iodata_to_binary()

    # Extract fingerprints from bitstring
    <<_::size(skip_bits), bucket::size(bucket_bit_size)-bitstring, _::bitstring>> = binary

    for <<fp::size(filter.fingerprint_bits)-big-unsigned-integer <- bucket>>, do: fp
  end

  # Matching Erlang update_in_bucket/5
  defp update_in_bucket(filter, index, sub_index, old_value, value) do
    bit_index =
      index * filter.bucket_size * filter.fingerprint_bits + sub_index * filter.fingerprint_bits

    atomic_idx = atomic_index(bit_index)
    skip_bits = band(bit_index, 63)
    atomic_value = :atomics.get(filter.atomics, atomic_idx)

    # Check if current value matches old_value using bitstring pattern matching
    case <<atomic_value::64-big-unsigned-integer>> do
      <<prefix::size(skip_bits)-bitstring,
        ^old_value::size(filter.fingerprint_bits)-big-unsigned-integer, suffix::bitstring>> ->
        # Build updated atomic word
        updated_binary =
          <<prefix::bitstring, value::size(filter.fingerprint_bits)-big-unsigned-integer,
            suffix::bitstring>>

        <<updated_atomic::64-big-unsigned-integer>> = updated_binary

        case :atomics.compare_exchange(filter.atomics, atomic_idx, atomic_value, updated_atomic) do
          :ok ->
            # Update counter (matching Erlang atomics:add/sub at index 3)
            case {old_value, value} do
              {0, _} -> :atomics.add(filter.atomics, @counter_index, 1)
              {_, 0} -> :atomics.sub(filter.atomics, @counter_index, 1)
              _ -> :ok
            end

          _ ->
            # Retry on CAS failure
            update_in_bucket(filter, index, sub_index, old_value, value)
        end

      _ ->
        {:error, :outdated}
    end
  end

  # Matching Erlang find_in_bucket/2,3
  defp find_in_bucket(bucket, fingerprint, index \\ 0)
  defp find_in_bucket([], _fingerprint, _index), do: {:error, :not_found}
  defp find_in_bucket([fingerprint | _], fingerprint, index), do: {:ok, index}

  defp find_in_bucket([_ | bucket], fingerprint, index),
    do: find_in_bucket(bucket, fingerprint, index + 1)

  # Matching Erlang insert_at_index/3
  defp insert_at_index(filter, index, fingerprint) do
    bucket = read_bucket(index, filter)

    # Check if fingerprint already exists (duplicate detection)
    case find_in_bucket(bucket, fingerprint) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        # Try to find empty slot
        case find_in_bucket(bucket, 0) do
          {:ok, sub_index} ->
            case update_in_bucket(filter, index, sub_index, 0, fingerprint) do
              :ok -> :ok
              {:error, :outdated} -> insert_at_index(filter, index, fingerprint)
            end

          {:error, :not_found} ->
            {:error, :full}
        end
    end
  end

  # Matching Erlang try_insert/7 with eviction cache
  defp try_insert(filter, index, fingerprint, r_state) do
    try_insert(filter, index, fingerprint, r_state, %{}, [], filter.bucket_size)
  end

  defp try_insert(_filter, _index, _fingerprint, _r_state, _evictions, _evictions_list, 0) do
    {:error, :full}
  end

  defp try_insert(
         %__MODULE__{max_kicks: max_kicks},
         _index,
         _fingerprint,
         _r_state,
         evictions,
         _evictions_list,
         _retry
       )
       when map_size(evictions) > max_kicks do
    {:error, :full}
  end

  defp try_insert(filter, index, fingerprint, r_state, evictions, evictions_list, retry) do
    bucket = read_bucket(index, filter)

    # Check for duplicate first
    case find_in_bucket(bucket, fingerprint) do
      {:ok, _} ->
        # Already exists, persist any pending evictions and succeed
        persist_evictions(filter, evictions, evictions_list, fingerprint)

      {:error, :not_found} ->
        # Try to find empty slot
        case find_in_bucket(bucket, 0) do
          {:ok, sub_index} ->
            case update_in_bucket(filter, index, sub_index, 0, fingerprint) do
              :ok ->
                persist_evictions(filter, evictions, evictions_list, fingerprint)

              {:error, :outdated} ->
                try_insert(filter, index, fingerprint, r_state, evictions, evictions_list, retry)
            end

          {:error, :not_found} ->
            # Randomly select slot for eviction (matching Erlang rand:mwc59)
            {sub_index, updated_r_state} = random_slot(r_state, filter.bucket_size)
            evicted = Enum.at(bucket, sub_index)
            key = {index, sub_index}

            if fingerprint == evicted or Map.has_key?(evictions, key) do
              try_insert(
                filter,
                index,
                fingerprint,
                updated_r_state,
                evictions,
                evictions_list,
                retry - 1
              )
            else
              alt_idx = alt_index(index, evicted, filter)

              try_insert(
                filter,
                alt_idx,
                evicted,
                updated_r_state,
                Map.put(evictions, key, fingerprint),
                [key | evictions_list],
                filter.bucket_size
              )
            end
        end
    end
  end

  # Matching Erlang persist_evictions/4
  defp persist_evictions(_filter, _evictions, [], _evicted), do: :ok

  defp persist_evictions(filter, evictions, [key = {index, sub_index} | evictions_list], evicted) do
    fingerprint = Map.get(evictions, key)
    :ok = update_in_bucket(filter, index, sub_index, evicted, fingerprint)
    persist_evictions(filter, evictions, evictions_list, fingerprint)
  end

  # Simplified random slot (matching Erlang's approach)
  defp random_slot(r_state, bucket_size) do
    {value, new_state} = :rand.uniform_s(bucket_size, r_state)
    {value - 1, new_state}
  end

  # Check if bucket contains fingerprint - fast inline check
  defp contains_fingerprint(filter, index, fingerprint) do
    bucket_bit_size = filter.bucket_size * filter.fingerprint_bits
    bit_index = index * bucket_bit_size
    atomic_idx = atomic_index(bit_index)
    skip_bits = band(bit_index, 63)
    end_idx = atomic_index(bit_index + bucket_bit_size - 1)

    # Fast path: bucket fits in single atomic word (common case)
    if atomic_idx == end_idx do
      word = :atomics.get(filter.atomics, atomic_idx)

      check_word_for_fingerprint(
        word,
        skip_bits,
        bucket_bit_size,
        fingerprint,
        filter.fingerprint_bits
      )
    else
      # Multi-word bucket
      binary =
        for i <- atomic_idx..end_idx, into: <<>> do
          <<:atomics.get(filter.atomics, i)::64-big-unsigned-integer>>
        end

      <<_::size(skip_bits), bucket::size(bucket_bit_size)-bitstring, _::bitstring>> = binary
      fingerprint_exists?(bucket, fingerprint, filter.fingerprint_bits)
    end
  end

  # Check single word for fingerprint without building binary
  defp check_word_for_fingerprint(word, skip_bits, bucket_bit_size, fingerprint, fp_bits) do
    <<_::size(skip_bits), bucket::size(bucket_bit_size)-bitstring, _::bitstring>> =
      <<word::64-big-unsigned-integer>>

    fingerprint_exists?(bucket, fingerprint, fp_bits)
  end

  # Check if fingerprint exists in bucket bitstring
  defp fingerprint_exists?(<<>>, _fingerprint, _bits), do: false

  defp fingerprint_exists?(bucket, fingerprint, bits) do
    case bucket do
      <<^fingerprint::size(bits)-big-unsigned-integer, _::bitstring>> ->
        true

      <<_::size(bits)-big-unsigned-integer, rest::bitstring>> ->
        fingerprint_exists?(rest, fingerprint, bits)
    end
  end

  # Delete fingerprint from bucket (matching Erlang delete_fingerprint/3)
  defp delete_fingerprint(filter, index, fingerprint) do
    bucket = read_bucket(index, filter)

    case find_in_bucket(bucket, fingerprint) do
      {:ok, sub_index} ->
        case update_in_bucket(filter, index, sub_index, fingerprint, 0) do
          :ok -> true
          {:error, :outdated} -> delete_fingerprint(filter, index, fingerprint)
        end

      {:error, :not_found} ->
        false
    end
  end

  defp required_bucket_count(capacity, bucket_size, load_factor) do
    Float.ceil(capacity / (bucket_size * load_factor))
    |> trunc()
    |> max(1)
  end

  defp empty_like(%__MODULE__{} = filter) do
    # Create a new filter with same configuration but empty
    bucket_bit_size = filter.bucket_count * filter.bucket_size * filter.fingerprint_bits
    atomics_size = div(bucket_bit_size + 63, 64) + 3
    atomics = :atomics.new(atomics_size, signed: false)

    %__MODULE__{
      atomics: atomics,
      bucket_count: filter.bucket_count,
      bucket_size: filter.bucket_size,
      fingerprint_bits: filter.fingerprint_bits,
      fingerprint_mask: filter.fingerprint_mask,
      max_kicks: filter.max_kicks,
      hash_module: filter.hash_module,
      capacity: filter.capacity
    }
  end

  defp ensure_compatible!(filters, reference) do
    Enum.each(filters, fn filter ->
      unless compatible?(filter, reference) do
        raise ArgumentError,
              "filters must share bucket_count, bucket_size, fingerprint_bits, and hash_module"
      end
    end)
  end

  defp compatible?(a, b) do
    a.bucket_count == b.bucket_count and a.bucket_size == b.bucket_size and
      a.fingerprint_bits == b.fingerprint_bits and a.hash_module == b.hash_module
  end

  defp recalculate_counter(filter) do
    # Count occupied slots by reading all buckets
    occupied =
      0..(filter.bucket_count - 1)
      |> Enum.reduce(0, fn index, acc ->
        bucket = read_bucket(index, filter)
        # Count non-zero fingerprints
        occupied_in_bucket = Enum.count(bucket, &(&1 != 0))
        acc + occupied_in_bucket
      end)

    :atomics.put(filter.atomics, @counter_index, occupied)
  end

  defp next_power_of_two(value) when value <= 1, do: 1

  defp next_power_of_two(value) do
    v = value - 1
    v = bor(v, v >>> 1)
    v = bor(v, v >>> 2)
    v = bor(v, v >>> 4)
    v = bor(v, v >>> 8)
    v = bor(v, v >>> 16)
    v = bor(v, v >>> 32)
    v + 1
  end

  defp validate_load_factor!(value) when is_number(value) and value > 0 and value < 1, do: value
  defp validate_load_factor!(_), do: raise(ArgumentError, "load factor must be between 0 and 1")

  defp validate_bucket_size!(value) when is_integer(value) and value > 0, do: value

  defp validate_bucket_size!(_),
    do: raise(ArgumentError, "bucket_size must be a positive integer")

  defp validate_fingerprint_bits!(value) when is_integer(value) and value > 0, do: value

  defp validate_fingerprint_bits!(_),
    do: raise(ArgumentError, "fingerprint_bits must be a positive integer")
end
