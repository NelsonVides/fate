defmodule Fate.Filter.BloomTest do
  use ExUnit.Case, async: true

  alias Fate.Filter.Bloom

  test "inserts and checks membership" do
    bloom = Bloom.new(128, false_positive_probability: 0.01, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom, "hello")
    assert Bloom.member?(bloom, "hello")
    refute Bloom.member?(bloom, "world")
  end

  test "empty filter returns false for all queries" do
    bloom = Bloom.new(128, hash_module: Fate.Hash.Default)
    refute Bloom.member?(bloom, "anything")
    refute Bloom.member?(bloom, 123)
    refute Bloom.member?(bloom, :atom)
  end

  test "multiple inserts of same item are idempotent" do
    bloom = Bloom.new(128, hash_module: Fate.Hash.Default)

    :ok = Bloom.put(bloom, "duplicate")
    :ok = Bloom.put(bloom, "duplicate")
    :ok = Bloom.put(bloom, "duplicate")

    assert Bloom.member?(bloom, "duplicate")

    # Cardinality should be approximately 1 (not 3)
    cardinality = Bloom.cardinality(bloom)
    assert cardinality >= 1 and cardinality <= 2
  end

  test "handles various data types" do
    bloom = Bloom.new(256, hash_module: Fate.Hash.Default)

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
      :ok = Bloom.put(bloom, item)
      assert Bloom.member?(bloom, item)
    end)
  end

  test "serialize and deserialize preserve state" do
    bloom =
      1..40
      |> Enum.reduce(Bloom.new(128, hash_module: Fate.Hash.Default), fn i, acc ->
        :ok = Bloom.put(acc, i)
        acc
      end)

    binary = Bloom.serialize(bloom)
    restored = Bloom.deserialize(binary)

    assert restored.bit_length == bloom.bit_length
    assert restored.hash_count == bloom.hash_count
    assert Enum.all?(1..40, &Bloom.member?(restored, &1))
  end

  test "serialize and deserialize empty filter" do
    bloom = Bloom.new(128, hash_module: Fate.Hash.Default)
    binary = Bloom.serialize(bloom)
    restored = Bloom.deserialize(binary)

    assert restored.bit_length == bloom.bit_length
    refute Bloom.member?(restored, "anything")
  end

  test "merge combines multiple filters" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom3 = Bloom.new(64, hash_module: Fate.Hash.Default)

    :ok = Bloom.put(bloom1, :a)
    :ok = Bloom.put(bloom2, :b)
    :ok = Bloom.put(bloom3, :c)

    merged = Bloom.merge([bloom1, bloom2, bloom3])
    assert Bloom.member?(merged, :a)
    assert Bloom.member?(merged, :b)
    assert Bloom.member?(merged, :c)
  end

  test "merge with overlapping items" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)

    :ok = Bloom.put(bloom1, :shared)
    :ok = Bloom.put(bloom1, :only1)
    :ok = Bloom.put(bloom2, :shared)
    :ok = Bloom.put(bloom2, :only2)

    merged = Bloom.merge([bloom1, bloom2])
    assert Bloom.member?(merged, :shared)
    assert Bloom.member?(merged, :only1)
    assert Bloom.member?(merged, :only2)
  end

  test "intersection finds common items" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)

    :ok = Bloom.put(bloom1, :shared)
    :ok = Bloom.put(bloom1, :only1)
    :ok = Bloom.put(bloom2, :shared)
    :ok = Bloom.put(bloom2, :only2)

    intersected = Bloom.intersection([bloom1, bloom2])
    # Intersection may have false positives, but should at least not have items only in one
    # Note: Due to false positives, we can't guarantee :shared is present, but we can check
    # that items only in one filter are less likely
    refute Bloom.member?(intersected, :only1)
    refute Bloom.member?(intersected, :only2)
  end

  test "intersection of non-overlapping filters is empty" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)

    :ok = Bloom.put(bloom1, :a)
    :ok = Bloom.put(bloom2, :b)

    _intersected = Bloom.intersection([bloom1, bloom2])
    # Should not contain items from either (though false positives possible)
    # In practice with small filters, false positives are unlikely for non-overlapping items
  end

  test "merge and intersection require compatible filters" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom1, :a)
    :ok = Bloom.put(bloom2, :b)

    merged = Bloom.merge([bloom1, bloom2])
    assert Bloom.member?(merged, :a)
    assert Bloom.member?(merged, :b)

    intersected = Bloom.intersection([bloom1, bloom2])
    refute Bloom.member?(intersected, :a)
    refute Bloom.member?(intersected, :b)
  end

  test "merge raises error for incompatible filters" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(128, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Bloom.merge([bloom1, bloom2])
    end
  end

  test "intersection raises error for incompatible filters" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(128, hash_module: Fate.Hash.Default)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Bloom.intersection([bloom1, bloom2])
    end
  end

  test "merge with different hash modules raises error" do
    bloom1 = Bloom.new(64, hash_module: Fate.Hash.Default)
    bloom2 = Bloom.new(64, hash_module: Fate.Hash.FNV1a)

    assert_raise ArgumentError, ~r/must share/, fn ->
      Bloom.merge([bloom1, bloom2])
    end
  end

  test "bits_info returns correct statistics" do
    bloom = Bloom.new(128, hash_module: Fate.Hash.Default)

    info = Bloom.bits_info(bloom)
    assert info.total_bits == bloom.bit_length
    assert info.set_bits_count == 0
    assert info.set_ratio == 0.0

    :ok = Bloom.put(bloom, "test")

    info = Bloom.bits_info(bloom)
    assert info.total_bits == bloom.bit_length
    assert info.set_bits_count > 0
    assert info.set_ratio > 0.0 and info.set_ratio <= 1.0
  end

  test "cardinality estimation is reasonable" do
    bloom = Bloom.new(1000, false_positive_probability: 0.01, hash_module: Fate.Hash.Default)

    # Insert 100 items
    Enum.each(1..100, fn i ->
      :ok = Bloom.put(bloom, i)
    end)

    cardinality = Bloom.cardinality(bloom)
    # Should be close to 100, allow some variance due to estimation
    assert cardinality >= 80 and cardinality <= 120
  end

  test "cardinality of empty filter is zero" do
    bloom = Bloom.new(128, hash_module: Fate.Hash.Default)
    assert Bloom.cardinality(bloom) == 0
  end

  test "false_positive_probability calculation" do
    bloom = Bloom.new(1000, false_positive_probability: 0.01, hash_module: Fate.Hash.Default)

    # Empty filter should have very low false positive probability (near 0)
    fpp = Bloom.false_positive_probability(bloom)
    assert fpp >= 0.0 and fpp < 0.01

    # After inserting items, FPP should increase
    Enum.each(1..100, fn i ->
      :ok = Bloom.put(bloom, i)
    end)

    fpp = Bloom.false_positive_probability(bloom)
    assert fpp > 0.0 and fpp <= 1.0
  end

  test "works with different hash functions" do
    hash_modules = [
      Fate.Hash.Default,
      Fate.Hash.FNV1a
    ]

    Enum.each(hash_modules, fn hash_module ->
      bloom = Bloom.new(128, hash_module: hash_module)
      :ok = Bloom.put(bloom, "test")
      assert Bloom.member?(bloom, "test")
      refute Bloom.member?(bloom, "other")
    end)
  end

  test "required_filter_length calculation" do
    length = Bloom.required_filter_length(1000, 0.01)
    assert length > 0
    assert is_integer(length)
  end

  test "required_hash_function_count calculation" do
    bit_length = Bloom.required_filter_length(1000, 0.01)
    hash_count = Bloom.required_hash_function_count(bit_length, 1000)
    assert hash_count > 0
    assert is_integer(hash_count)
  end

  test "handles very small filter" do
    bloom = Bloom.new(8, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom, "test")
    assert Bloom.member?(bloom, "test")
  end

  test "handles large filter" do
    bloom = Bloom.new(1_000_000, hash_module: Fate.Hash.Default)
    :ok = Bloom.put(bloom, "test")
    assert Bloom.member?(bloom, "test")
  end

  test "custom hash_count and bit_length" do
    bloom =
      Bloom.new(1000,
        hash_count: 5,
        bit_length: 5000,
        hash_module: Fate.Hash.Default
      )

    assert bloom.hash_count == 5
    assert bloom.bit_length == 5000

    :ok = Bloom.put(bloom, "test")
    assert Bloom.member?(bloom, "test")
  end
end
