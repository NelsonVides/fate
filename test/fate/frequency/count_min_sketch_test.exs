defmodule Fate.Frequency.CountMinSketchTest do
  use ExUnit.Case, async: true

  alias Fate.Frequency.CountMinSketch

  # -- Creation ----------------------------------------------------------------

  test "creates sketch with explicit width and depth" do
    sketch = CountMinSketch.new(width: 100, depth: 5, hash_module: Fate.Hash.Default)
    assert sketch.width == 100
    assert sketch.depth == 5
    assert sketch.hash_module == Fate.Hash.Default
  end

  test "creates sketch from epsilon and delta" do
    sketch = CountMinSketch.new(epsilon: 0.01, delta: 0.01, hash_module: Fate.Hash.Default)
    # width = ceil(e / 0.01) = ceil(271.8) = 272
    assert sketch.width == 272
    # depth = ceil(ln(1/0.01)) = ceil(4.605) = 5
    assert sketch.depth == 5
  end

  test "raises when both error-bound and explicit dimensions given" do
    assert_raise ArgumentError, ~r/not both/, fn ->
      CountMinSketch.new(epsilon: 0.01, delta: 0.01, width: 100, depth: 5)
    end
  end

  test "raises when neither dimensions nor error bounds given" do
    assert_raise ArgumentError, ~r/must provide/, fn ->
      CountMinSketch.new(hash_module: Fate.Hash.Default)
    end
  end

  test "raises on invalid epsilon" do
    assert_raise ArgumentError, ~r/epsilon/, fn ->
      CountMinSketch.new(epsilon: 0, delta: 0.01)
    end

    assert_raise ArgumentError, ~r/epsilon/, fn ->
      CountMinSketch.new(epsilon: 1, delta: 0.01)
    end

    assert_raise ArgumentError, ~r/epsilon/, fn ->
      CountMinSketch.new(epsilon: -0.5, delta: 0.01)
    end
  end

  test "raises on invalid delta" do
    assert_raise ArgumentError, ~r/delta/, fn ->
      CountMinSketch.new(epsilon: 0.01, delta: 0)
    end

    assert_raise ArgumentError, ~r/delta/, fn ->
      CountMinSketch.new(epsilon: 0.01, delta: 1)
    end
  end

  test "raises on invalid width or depth" do
    assert_raise ArgumentError, ~r/width/, fn ->
      CountMinSketch.new(width: 0, depth: 5)
    end

    assert_raise ArgumentError, ~r/depth/, fn ->
      CountMinSketch.new(width: 100, depth: -1)
    end
  end

  test "raises on unavailable hash module" do
    assert_raise ArgumentError, fn ->
      CountMinSketch.new(width: 100, depth: 5, hash_module: FakeHashModule)
    end
  end

  # -- Put & Estimate ----------------------------------------------------------

  test "put and estimate for single item" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)

    :ok = CountMinSketch.put(sketch, "hello")
    :ok = CountMinSketch.put(sketch, "hello")
    :ok = CountMinSketch.put(sketch, "hello")

    assert CountMinSketch.estimate(sketch, "hello") >= 3
  end

  test "estimate for unseen item returns 0" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)
    assert CountMinSketch.estimate(sketch, "never_inserted") == 0
  end

  test "estimate is always >= true count (never underestimates)" do
    sketch = CountMinSketch.new(width: 2048, depth: 7, hash_module: Fate.Hash.Default)

    # Insert items with known frequencies
    frequencies = %{"a" => 10, "b" => 50, "c" => 100, "d" => 1}

    Enum.each(frequencies, fn {item, count} ->
      Enum.each(1..count, fn _ -> CountMinSketch.put(sketch, item) end)
    end)

    Enum.each(frequencies, fn {item, true_count} ->
      estimated = CountMinSketch.estimate(sketch, item)

      assert estimated >= true_count,
             "estimate #{estimated} < true count #{true_count} for #{item}"
    end)
  end

  # -- Update with count -------------------------------------------------------

  test "update increments by arbitrary count" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)

    :ok = CountMinSketch.update(sketch, "item", 42)

    assert CountMinSketch.estimate(sketch, "item") >= 42
  end

  test "update and put are consistent" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)

    :ok = CountMinSketch.put(sketch, "x")
    :ok = CountMinSketch.put(sketch, "x")
    :ok = CountMinSketch.put(sketch, "x")
    :ok = CountMinSketch.update(sketch, "x", 7)

    assert CountMinSketch.estimate(sketch, "x") >= 10
  end

  # -- Accuracy ----------------------------------------------------------------

  test "accuracy is within epsilon * N bounds" do
    epsilon = 0.01
    delta = 0.01
    sketch = CountMinSketch.new(epsilon: epsilon, delta: delta, hash_module: Fate.Hash.FNV1a)

    n = 10_000

    # Insert n items, each once
    Enum.each(1..n, fn i -> CountMinSketch.put(sketch, i) end)

    # For each item, estimate should be >= 1 and <= 1 + epsilon * N
    max_overcount = epsilon * n

    violations =
      Enum.count(1..n, fn i ->
        est = CountMinSketch.estimate(sketch, i)
        est < 1 or est > 1 + max_overcount
      end)

    # With delta = 0.01, at most ~1% of items should violate the bound
    assert violations / n < delta + 0.01,
           "#{violations}/#{n} items violated error bound (expected < #{delta + 0.01})"
  end

  # -- Data types --------------------------------------------------------------

  test "handles various data types" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)

    items = [
      "string",
      123,
      :atom,
      {:tuple, "with", "values"},
      [1, 2, 3],
      %{map: "value"},
      true,
      nil
    ]

    Enum.each(items, fn item ->
      :ok = CountMinSketch.put(sketch, item)
      assert CountMinSketch.estimate(sketch, item) >= 1
    end)
  end

  # -- Merge -------------------------------------------------------------------

  test "merge combines multiple sketches" do
    s1 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..5, fn _ -> CountMinSketch.put(s1, "a") end)
    Enum.each(1..3, fn _ -> CountMinSketch.put(s2, "a") end)
    Enum.each(1..7, fn _ -> CountMinSketch.put(s2, "b") end)

    merged = CountMinSketch.merge([s1, s2])

    assert CountMinSketch.estimate(merged, "a") >= 8
    assert CountMinSketch.estimate(merged, "b") >= 7
  end

  test "merge raises for incompatible sketches" do
    s1 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 1024, depth: 5, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share/, fn ->
      CountMinSketch.merge([s1, s2])
    end
  end

  test "merge raises for different hash modules" do
    s1 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.FNV1a)

    assert_raise ArgumentError, ~r/must share/, fn ->
      CountMinSketch.merge([s1, s2])
    end
  end

  # -- Serialization -----------------------------------------------------------

  test "serialize and deserialize preserve state" do
    sketch = CountMinSketch.new(width: 256, depth: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..20, fn i ->
      CountMinSketch.update(sketch, i, i)
    end)

    binary = CountMinSketch.serialize(sketch)
    restored = CountMinSketch.deserialize(binary)

    assert restored.width == sketch.width
    assert restored.depth == sketch.depth
    assert restored.hash_module == sketch.hash_module

    Enum.each(1..20, fn i ->
      assert CountMinSketch.estimate(restored, i) == CountMinSketch.estimate(sketch, i)
    end)
  end

  test "serialize and deserialize empty sketch" do
    sketch = CountMinSketch.new(width: 64, depth: 3, hash_module: Fate.Hash.Default)
    binary = CountMinSketch.serialize(sketch)
    restored = CountMinSketch.deserialize(binary)

    assert restored.width == 64
    assert restored.depth == 3
    assert CountMinSketch.estimate(restored, "anything") == 0
  end

  # -- Reset -------------------------------------------------------------------

  test "reset returns empty sketch with same configuration" do
    sketch = CountMinSketch.new(width: 128, depth: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..50, fn i -> CountMinSketch.put(sketch, i) end)
    assert CountMinSketch.estimate(sketch, 1) >= 1

    fresh = CountMinSketch.reset(sketch)
    assert fresh.width == sketch.width
    assert fresh.depth == sketch.depth
    assert fresh.hash_module == sketch.hash_module
    assert CountMinSketch.estimate(fresh, 1) == 0
  end

  # -- Edge cases --------------------------------------------------------------

  test "single row sketch works" do
    sketch = CountMinSketch.new(width: 1024, depth: 1, hash_module: Fate.Hash.Default)
    :ok = CountMinSketch.put(sketch, "test")
    assert CountMinSketch.estimate(sketch, "test") >= 1
  end

  test "single column sketch works" do
    sketch = CountMinSketch.new(width: 1, depth: 5, hash_module: Fate.Hash.Default)
    :ok = CountMinSketch.put(sketch, "a")
    :ok = CountMinSketch.put(sketch, "b")
    # With width=1, all items collide — estimate should be total count
    assert CountMinSketch.estimate(sketch, "a") == 2
    assert CountMinSketch.estimate(sketch, "b") == 2
  end

  test "works with different hash functions" do
    hash_modules = [Fate.Hash.Default, Fate.Hash.FNV1a]

    Enum.each(hash_modules, fn hash_module ->
      sketch = CountMinSketch.new(width: 256, depth: 5, hash_module: hash_module)
      :ok = CountMinSketch.put(sketch, "test")
      assert CountMinSketch.estimate(sketch, "test") >= 1
    end)
  end

  # -- Heavy hitter tracking ---------------------------------------------------

  test "top-k tracks heavy hitters" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, top_k: 3, hash_module: Fate.Hash.Default)

    # Insert items with distinct frequencies
    Enum.each(1..100, fn _ -> CountMinSketch.put(sketch, "high") end)
    Enum.each(1..50, fn _ -> CountMinSketch.put(sketch, "medium") end)
    Enum.each(1..10, fn _ -> CountMinSketch.put(sketch, "low") end)

    results = CountMinSketch.top(sketch)
    assert length(results) == 3

    # Results should be sorted descending by estimate
    [{item1, est1}, {item2, est2}, {item3, est3}] = results
    assert item1 == "high"
    assert item2 == "medium"
    assert item3 == "low"
    assert est1 >= est2
    assert est2 >= est3
  end

  test "top returns empty list when top_k not enabled" do
    sketch = CountMinSketch.new(width: 256, depth: 5, hash_module: Fate.Hash.Default)
    :ok = CountMinSketch.put(sketch, "item")
    assert CountMinSketch.top(sketch) == []
  end

  test "new item below true minimum does not evict after min item grows" do
    sketch = CountMinSketch.new(width: 2048, depth: 5, top_k: 2, hash_module: Fate.Hash.Default)

    Enum.each(1..100, fn _ -> CountMinSketch.put(sketch, "a") end)
    Enum.each(1..300, fn _ -> CountMinSketch.put(sketch, "b") end)
    # former min now increases
    Enum.each(1..400, fn _ -> CountMinSketch.put(sketch, "a") end)
    Enum.each(1..120, fn _ -> CountMinSketch.put(sketch, "c") end)

    items = CountMinSketch.top(sketch) |> Enum.map(&elem(&1, 0))
    assert "a" in items
    assert "b" in items
    refute "c" in items
  end

  test "heap evicts lowest when full" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, top_k: 3, hash_module: Fate.Hash.Default)

    # Fill the heap with 3 items
    Enum.each(1..10, fn _ -> CountMinSketch.put(sketch, "a") end)
    Enum.each(1..20, fn _ -> CountMinSketch.put(sketch, "b") end)
    Enum.each(1..30, fn _ -> CountMinSketch.put(sketch, "c") end)

    assert length(CountMinSketch.top(sketch)) == 3

    # Insert a new heavy hitter that should evict "a" (lowest count)
    Enum.each(1..50, fn _ -> CountMinSketch.put(sketch, "d") end)

    items = CountMinSketch.top(sketch) |> Enum.map(fn {item, _} -> item end)
    assert length(items) == 3
    assert "d" in items
    assert "c" in items
    assert "b" in items
    refute "a" in items
  end

  test "heavy_hitter? returns correct results" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, top_k: 2, hash_module: Fate.Hash.Default)

    Enum.each(1..20, fn _ -> CountMinSketch.put(sketch, "tracked") end)
    Enum.each(1..10, fn _ -> CountMinSketch.put(sketch, "also_tracked") end)

    assert CountMinSketch.heavy_hitter?(sketch, "tracked")
    assert CountMinSketch.heavy_hitter?(sketch, "also_tracked")
    refute CountMinSketch.heavy_hitter?(sketch, "not_here")
  end

  test "heavy_hitter? returns false when top_k not enabled" do
    sketch = CountMinSketch.new(width: 256, depth: 5, hash_module: Fate.Hash.Default)
    :ok = CountMinSketch.put(sketch, "item")
    refute CountMinSketch.heavy_hitter?(sketch, "item")
  end

  test "heap updates estimate for existing item" do
    sketch = CountMinSketch.new(width: 1024, depth: 5, top_k: 5, hash_module: Fate.Hash.Default)

    :ok = CountMinSketch.put(sketch, "x")
    [{_item, est1}] = CountMinSketch.top(sketch)

    Enum.each(1..10, fn _ -> CountMinSketch.put(sketch, "x") end)
    [{_item, est2}] = CountMinSketch.top(sketch)

    assert est2 > est1
  end

  test "raises on invalid top_k" do
    assert_raise ArgumentError, ~r/top_k/, fn ->
      CountMinSketch.new(width: 100, depth: 5, top_k: 0)
    end

    assert_raise ArgumentError, ~r/top_k/, fn ->
      CountMinSketch.new(width: 100, depth: 5, top_k: -1)
    end
  end

  # -- Merge with heaps --------------------------------------------------------

  test "merge combines heaps by re-querying merged CMS" do
    s1 = CountMinSketch.new(width: 1024, depth: 5, top_k: 10, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 1024, depth: 5, top_k: 10, hash_module: Fate.Hash.Default)

    Enum.each(1..50, fn _ -> CountMinSketch.put(s1, "a") end)
    Enum.each(1..30, fn _ -> CountMinSketch.put(s2, "a") end)
    Enum.each(1..40, fn _ -> CountMinSketch.put(s2, "b") end)

    merged = CountMinSketch.merge([s1, s2])

    results = CountMinSketch.top(merged)
    items = Enum.map(results, fn {item, _} -> item end)
    assert "a" in items
    assert "b" in items

    # "a" should have combined count >= 80
    {_, a_est} = Enum.find(results, fn {item, _} -> item == "a" end)
    assert a_est >= 80
  end

  test "merge with custom output top_k" do
    s1 = CountMinSketch.new(width: 1024, depth: 5, top_k: 10, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 1024, depth: 5, top_k: 10, hash_module: Fate.Hash.Default)

    # Insert 8 distinct items across both sketches
    Enum.each(1..8, fn i ->
      sketch = if rem(i, 2) == 0, do: s1, else: s2
      Enum.each(1..(i * 10), fn _ -> CountMinSketch.put(sketch, "item_#{i}") end)
    end)

    # Merge into a smaller top_k
    merged = CountMinSketch.merge([s1, s2], top_k: 3)
    results = CountMinSketch.top(merged)
    assert length(results) == 3

    # Should contain the 3 highest-frequency items
    items = Enum.map(results, fn {item, _} -> item end)
    assert "item_8" in items
    assert "item_7" in items
    assert "item_6" in items
  end

  test "merge works when some sketches have no heap" do
    s1 = CountMinSketch.new(width: 512, depth: 5, top_k: 5, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..10, fn _ -> CountMinSketch.put(s1, "tracked") end)
    Enum.each(1..10, fn _ -> CountMinSketch.put(s2, "untracked") end)

    merged = CountMinSketch.merge([s1, s2])
    results = CountMinSketch.top(merged)

    # Only "tracked" was in a heap, so only it is a candidate
    items = Enum.map(results, fn {item, _} -> item end)
    assert "tracked" in items
  end

  test "merge without any heaps produces no heap" do
    s1 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)
    s2 = CountMinSketch.new(width: 512, depth: 5, hash_module: Fate.Hash.Default)

    :ok = CountMinSketch.put(s1, "a")
    :ok = CountMinSketch.put(s2, "b")

    merged = CountMinSketch.merge([s1, s2])
    assert CountMinSketch.top(merged) == []
  end

  # -- Serialization with heap -------------------------------------------------

  test "serialize and deserialize preserve heap state" do
    sketch = CountMinSketch.new(width: 512, depth: 5, top_k: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..50, fn _ -> CountMinSketch.put(sketch, "heavy") end)
    Enum.each(1..20, fn _ -> CountMinSketch.put(sketch, "medium") end)
    Enum.each(1..5, fn _ -> CountMinSketch.put(sketch, "light") end)

    binary = CountMinSketch.serialize(sketch)
    restored = CountMinSketch.deserialize(binary)

    assert restored.top_k == sketch.top_k

    orig_top = CountMinSketch.top(sketch)
    restored_top = CountMinSketch.top(restored)

    assert length(orig_top) == length(restored_top)

    orig_items = MapSet.new(orig_top, fn {item, _} -> item end)
    restored_items = MapSet.new(restored_top, fn {item, _} -> item end)
    assert MapSet.equal?(orig_items, restored_items)
  end

  test "reset clears heap" do
    sketch = CountMinSketch.new(width: 256, depth: 5, top_k: 5, hash_module: Fate.Hash.Default)

    Enum.each(1..20, fn _ -> CountMinSketch.put(sketch, "item") end)
    assert length(CountMinSketch.top(sketch)) == 1

    fresh = CountMinSketch.reset(sketch)
    assert fresh.top_k == 5
    assert CountMinSketch.top(fresh) == []
    assert CountMinSketch.estimate(fresh, "item") == 0
  end
end
