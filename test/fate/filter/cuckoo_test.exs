defmodule Fate.Filter.CuckooTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Fate.Filter.Cuckoo

  setup do
    %{filter: Cuckoo.new(128, hash_module: Fate.Hash.Default)}
  end

  test "put/member?/size is consistent", %{filter: filter} do
    values = Enum.to_list(1..50)

    Enum.each(values, fn value ->
      assert :ok = Cuckoo.put(filter, value)
    end)

    Enum.each(values, fn value ->
      assert Cuckoo.member?(filter, value)
    end)

    assert Cuckoo.size(filter) == 50

    # reinserting same values should not change size
    Enum.each(values, fn value ->
      assert :ok = Cuckoo.put(filter, value)
    end)

    assert Cuckoo.size(filter) == 50
  end

  test "empty filter returns false for all queries" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)
    refute Cuckoo.member?(filter, "anything")
    refute Cuckoo.member?(filter, 123)
    refute Cuckoo.member?(filter, :atom)
    assert Cuckoo.size(filter) == 0
  end

  test "delete removes fingerprints and updates size", %{filter: filter} do
    :ok = Cuckoo.put(filter, "alpha")
    :ok = Cuckoo.put(filter, "beta")
    assert Cuckoo.member?(filter, "alpha")
    assert Cuckoo.size(filter) == 2

    assert :ok = Cuckoo.delete(filter, "alpha")
    refute Cuckoo.member?(filter, "alpha")
    assert Cuckoo.size(filter) == 1

    assert :not_found = Cuckoo.delete(filter, "gamma")
  end

  test "delete non-existent item returns not_found" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)
    assert :not_found = Cuckoo.delete(filter, "nonexistent")
  end

  test "delete and reinsert same item" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter, "item")
    assert Cuckoo.size(filter) == 1

    :ok = Cuckoo.delete(filter, "item")
    assert Cuckoo.size(filter) == 0
    refute Cuckoo.member?(filter, "item")

    :ok = Cuckoo.put(filter, "item")
    assert Cuckoo.size(filter) == 1
    assert Cuckoo.member?(filter, "item")
  end

  test "multiple deletes of same item" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter, "item")
    :ok = Cuckoo.delete(filter, "item")
    assert :not_found = Cuckoo.delete(filter, "item")
    assert :not_found = Cuckoo.delete(filter, "item")
  end

  test "handles various data types" do
    filter = Cuckoo.new(256, hash_module: Fate.Hash.Default)

    test_items = [
      "string",
      123,
      :atom,
      {:tuple, "with", "values"},
      [1, 2, 3],
      %{map: "value"},
      true,
      false,
      nil
    ]

    Enum.each(test_items, fn item ->
      :ok = Cuckoo.put(filter, item)
      assert Cuckoo.member?(filter, item)
    end)

    assert Cuckoo.size(filter) == length(test_items)

    # Delete all
    Enum.each(test_items, fn item ->
      :ok = Cuckoo.delete(filter, item)
    end)

    assert Cuckoo.size(filter) == 0
  end

  test "capacity returns correct value" do
    filter = Cuckoo.new(1000, hash_module: Fate.Hash.Default)
    assert Cuckoo.capacity(filter) == 1000

    filter2 = Cuckoo.new(500, hash_module: Fate.Hash.Default)
    assert Cuckoo.capacity(filter2) == 500
  end

  test "load_factor calculation" do
    filter = Cuckoo.new(100, hash_module: Fate.Hash.Default)

    # Empty filter
    load = Cuckoo.load_factor(filter)
    assert load == 0.0

    # Insert some items
    Enum.each(1..10, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    load = Cuckoo.load_factor(filter)
    assert load > 0.0 and load <= 1.0

    # Load factor should increase with more items
    Enum.each(11..50, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    new_load = Cuckoo.load_factor(filter)
    assert new_load > load
  end

  test "size tracks insertions and deletions correctly" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    assert Cuckoo.size(filter) == 0

    :ok = Cuckoo.put(filter, "a")
    assert Cuckoo.size(filter) == 1

    :ok = Cuckoo.put(filter, "b")
    assert Cuckoo.size(filter) == 2

    :ok = Cuckoo.put(filter, "c")
    assert Cuckoo.size(filter) == 3

    :ok = Cuckoo.delete(filter, "b")
    assert Cuckoo.size(filter) == 2

    :ok = Cuckoo.delete(filter, "a")
    assert Cuckoo.size(filter) == 1

    :ok = Cuckoo.delete(filter, "c")
    assert Cuckoo.size(filter) == 0
  end

  test "duplicate inserts don't increase size" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter, "duplicate")
    assert Cuckoo.size(filter) == 1

    :ok = Cuckoo.put(filter, "duplicate")
    assert Cuckoo.size(filter) == 1

    :ok = Cuckoo.put(filter, "duplicate")
    assert Cuckoo.size(filter) == 1
  end

  test "eventually reports {:error, :full} when saturated" do
    filter =
      Cuckoo.new(4,
        bucket_size: 2,
        fingerprint_bits: 6,
        max_kicks: 5,
        hash_module: Fate.Hash.Default
      )

    result =
      Enum.reduce_while(1..200, :ok, fn value, _ ->
        case Cuckoo.put(filter, {:value, value}) do
          :ok -> {:cont, :ok}
          {:error, :full} -> {:halt, :full}
        end
      end)

    assert result == :full
  end

  test "handles very small filter" do
    filter = Cuckoo.new(2, bucket_size: 1, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter, "a")
    assert Cuckoo.member?(filter, "a")

    # Should eventually fill up
    case Cuckoo.put(filter, "b") do
      :ok -> :ok
      {:error, :full} -> :full
    end
  end

  test "handles large filter" do
    filter = Cuckoo.new(100_000, hash_module: Fate.Hash.Default)

    Enum.each(1..1000, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    assert Cuckoo.size(filter) == 1000

    Enum.each(1..1000, fn i ->
      assert Cuckoo.member?(filter, i)
    end)
  end

  test "custom bucket_size" do
    filter =
      Cuckoo.new(100,
        bucket_size: 8,
        hash_module: Fate.Hash.Default
      )

    Enum.each(1..50, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    assert Cuckoo.size(filter) == 50
  end

  test "custom fingerprint_bits" do
    filter =
      Cuckoo.new(100,
        fingerprint_bits: 8,
        hash_module: Fate.Hash.Default
      )

    :ok = Cuckoo.put(filter, "test")
    assert Cuckoo.member?(filter, "test")
  end

  test "custom max_kicks" do
    filter =
      Cuckoo.new(100,
        max_kicks: 10,
        hash_module: Fate.Hash.Default
      )

    Enum.each(1..50, fn i ->
      case Cuckoo.put(filter, i) do
        :ok -> :ok
        {:error, :full} -> :full
      end
    end)
  end

  test "custom load_factor" do
    filter =
      Cuckoo.new(100,
        load_factor: 0.8,
        hash_module: Fate.Hash.Default
      )

    :ok = Cuckoo.put(filter, "test")
    assert Cuckoo.member?(filter, "test")
  end

  test "works with different hash functions" do
    hash_modules = [
      Fate.Hash.Default,
      Fate.Hash.FNV1a
    ]

    Enum.each(hash_modules, fn hash_module ->
      filter = Cuckoo.new(128, hash_module: hash_module)
      :ok = Cuckoo.put(filter, "test")
      assert Cuckoo.member?(filter, "test")
      refute Cuckoo.member?(filter, "other")

      :ok = Cuckoo.delete(filter, "test")
      refute Cuckoo.member?(filter, "test")
    end)
  end

  test "items can be in either bucket" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    # Insert items that may hash to different buckets
    items = ["item1", "item2", "item3", "item4", "item5"]

    Enum.each(items, fn item ->
      :ok = Cuckoo.put(filter, item)
      assert Cuckoo.member?(filter, item)
    end)

    # All should still be present
    Enum.each(items, fn item ->
      assert Cuckoo.member?(filter, item)
    end)
  end

  test "relocation works when primary bucket is full" do
    filter =
      Cuckoo.new(10,
        bucket_size: 2,
        max_kicks: 100,
        hash_module: Fate.Hash.Default
      )

    # Insert enough items to trigger relocations
    results =
      Enum.map(1..20, fn i ->
        {i, Cuckoo.put(filter, i)}
      end)

    # Some should succeed
    successful = Enum.filter(results, fn {_, result} -> result == :ok end)
    assert length(successful) > 0

    # Check that successfully inserted items are present
    # Note: Some items may have been evicted during later relocations,
    # so we check that at least some remain
    present =
      Enum.filter(successful, fn {item, _} ->
        Cuckoo.member?(filter, item)
      end)

    # At least some items should still be present (relocations happened)
    assert length(present) > 0
  end

  test "size never goes negative" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    # Try to delete from empty filter
    :not_found = Cuckoo.delete(filter, "nonexistent")
    assert Cuckoo.size(filter) == 0

    # Delete more than we insert
    :ok = Cuckoo.put(filter, "a")
    :ok = Cuckoo.delete(filter, "a")
    :not_found = Cuckoo.delete(filter, "a")
    :not_found = Cuckoo.delete(filter, "b")

    assert Cuckoo.size(filter) >= 0
  end

  test "load_factor never exceeds 1.0" do
    filter = Cuckoo.new(100, hash_module: Fate.Hash.Default)

    # Fill up the filter as much as possible
    Enum.each(1..1000, fn i ->
      case Cuckoo.put(filter, i) do
        :ok -> :ok
        {:error, :full} -> :full
      end
    end)

    load = Cuckoo.load_factor(filter)
    assert load >= 0.0 and load <= 1.0
  end

  test "capacity is power of two or close" do
    filter1 = Cuckoo.new(100, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(128, hash_module: Fate.Hash.Default)
    filter3 = Cuckoo.new(200, hash_module: Fate.Hash.Default)

    # Bucket count should be power of two
    assert band(filter1.bucket_count, filter1.bucket_count - 1) == 0
    assert band(filter2.bucket_count, filter2.bucket_count - 1) == 0
    assert band(filter3.bucket_count, filter3.bucket_count - 1) == 0
  end

  test "handles edge case with single bucket" do
    filter =
      Cuckoo.new(1,
        bucket_size: 1,
        hash_module: Fate.Hash.Default
      )

    :ok = Cuckoo.put(filter, "a")
    assert Cuckoo.member?(filter, "a")

    case Cuckoo.put(filter, "b") do
      :ok -> :ok
      {:error, :full} -> :full
    end
  end

  test "serialize and deserialize preserve state" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    Enum.each(1..50, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    binary = Cuckoo.serialize(filter)
    restored = Cuckoo.deserialize(binary)

    assert restored.bucket_count == filter.bucket_count
    assert restored.bucket_size == filter.bucket_size
    assert restored.fingerprint_bits == filter.fingerprint_bits
    assert Cuckoo.size(restored) == Cuckoo.size(filter)

    Enum.each(1..50, fn i ->
      assert Cuckoo.member?(restored, i)
    end)
  end

  test "serialize and deserialize empty filter" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)
    binary = Cuckoo.serialize(filter)
    restored = Cuckoo.deserialize(binary)

    assert Cuckoo.size(restored) == 0
    refute Cuckoo.member?(restored, "anything")
  end

  test "merge combines multiple filters" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter3 = Cuckoo.new(64, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter1, :a)
    :ok = Cuckoo.put(filter2, :b)
    :ok = Cuckoo.put(filter3, :c)

    merged = Cuckoo.merge([filter1, filter2, filter3])
    assert Cuckoo.member?(merged, :a)
    assert Cuckoo.member?(merged, :b)
    assert Cuckoo.member?(merged, :c)
  end

  test "merge with overlapping items" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(64, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter1, :shared)
    :ok = Cuckoo.put(filter1, :only1)
    :ok = Cuckoo.put(filter2, :shared)
    :ok = Cuckoo.put(filter2, :only2)

    merged = Cuckoo.merge([filter1, filter2])
    assert Cuckoo.member?(merged, :shared)
    assert Cuckoo.member?(merged, :only1)
    assert Cuckoo.member?(merged, :only2)
  end

  test "intersection finds common items" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(64, hash_module: Fate.Hash.Default)

    :ok = Cuckoo.put(filter1, :shared)
    :ok = Cuckoo.put(filter1, :only1)
    :ok = Cuckoo.put(filter2, :shared)
    :ok = Cuckoo.put(filter2, :only2)

    intersected = Cuckoo.intersection([filter1, filter2])
    # Intersection should contain shared items
    assert Cuckoo.member?(intersected, :shared)
  end

  test "merge raises error for incompatible filters" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Cuckoo.merge([filter1, filter2])
    end
  end

  test "intersection raises error for incompatible filters" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Cuckoo.intersection([filter1, filter2])
    end
  end

  test "merge with different hash modules raises error" do
    filter1 = Cuckoo.new(64, hash_module: Fate.Hash.Default)
    filter2 = Cuckoo.new(64, hash_module: Fate.Hash.FNV1a)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Cuckoo.merge([filter1, filter2])
    end
  end

  test "bits_info returns correct statistics" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    info = Cuckoo.bits_info(filter)
    assert info.total_slots > 0
    assert info.occupied_slots == 0
    assert info.load_ratio == 0.0
    assert info.total_bits > 0

    :ok = Cuckoo.put(filter, "test")

    info = Cuckoo.bits_info(filter)
    assert info.occupied_slots == 1
    assert info.load_ratio > 0.0 and info.load_ratio <= 1.0
  end

  test "cardinality matches size" do
    filter = Cuckoo.new(128, hash_module: Fate.Hash.Default)

    assert Cuckoo.cardinality(filter) == Cuckoo.size(filter)
    assert Cuckoo.cardinality(filter) == 0

    Enum.each(1..10, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    assert Cuckoo.cardinality(filter) == Cuckoo.size(filter)
    assert Cuckoo.cardinality(filter) == 10
  end

  test "false_positive_probability calculation" do
    filter = Cuckoo.new(1000, hash_module: Fate.Hash.Default)

    # Empty filter should have very low FPP
    fpp = Cuckoo.false_positive_probability(filter)
    assert fpp >= 0.0 and fpp <= 1.0

    # After inserting items, FPP should increase
    Enum.each(1..100, fn i ->
      :ok = Cuckoo.put(filter, i)
    end)

    fpp = Cuckoo.false_positive_probability(filter)
    assert fpp > 0.0 and fpp <= 1.0
  end
end
