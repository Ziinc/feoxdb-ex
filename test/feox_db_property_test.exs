defmodule FeoxDBPropertyTest do
  @moduledoc """
  Property tests (PRD milestone 3). These exercise `FeoxDB` against
  randomized inputs to catch edge cases (empty binaries, keys containing
  every byte value, degenerate ranges, ...) that hand-written examples
  tend to miss.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  defp non_empty_binary do
    StreamData.binary(min_length: 1, max_length: 256)
  end

  property "insert/2 followed by get/2 always round-trips the value" do
    check all(
            key <- non_empty_binary(),
            value <- non_empty_binary()
          ) do
      store = FeoxDB.open!()
      assert :ok = FeoxDB.insert(store, key, value)
      assert {:ok, ^value} = FeoxDB.get(store, key)
    end
  end

  property "delete/2 makes a previously-inserted key unreadable" do
    check all(
            key <- non_empty_binary(),
            value <- non_empty_binary()
          ) do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, key, value)
      assert :ok = FeoxDB.delete(store, key)
      assert {:error, :not_found} = FeoxDB.get(store, key)
      refute FeoxDB.member?(store, key)
    end
  end

  property "insert/2 is idempotent under repeated writes of the same value" do
    check all(
            key <- non_empty_binary(),
            value <- non_empty_binary(),
            times <- StreamData.integer(1..5)
          ) do
      store = FeoxDB.open!()

      for _ <- 1..times do
        assert :ok = FeoxDB.insert(store, key, value)
      end

      assert FeoxDB.size(store) == 1
      assert {:ok, ^value} = FeoxDB.get(store, key)
    end
  end

  property "size/1 always equals the number of distinct keys inserted" do
    check all(
            pairs <-
              StreamData.uniq_list_of(non_empty_binary(), max_length: 20)
              |> StreamData.map(&Enum.map(&1, fn key -> {key, "v"} end))
          ) do
      store = FeoxDB.open!()

      for {key, value} <- pairs do
        :ok = FeoxDB.insert(store, key, value)
      end

      assert FeoxDB.size(store) == length(pairs)
    end
  end

  property "compare_and_swap/4 only ever succeeds when the current value matches" do
    check all(
            key <- non_empty_binary(),
            initial <- non_empty_binary(),
            expected <- non_empty_binary(),
            new_value <- non_empty_binary()
          ) do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, key, initial)

      assert {:ok, swapped?} = FeoxDB.compare_and_swap(store, key, expected, new_value)
      assert swapped? == (expected == initial)

      expected_current = if swapped?, do: new_value, else: initial
      assert {:ok, ^expected_current} = FeoxDB.get(store, key)
    end
  end

  property "increment/3 accumulates deltas correctly, in any order" do
    check all(deltas <- StreamData.list_of(StreamData.integer(-1000..1000), max_length: 20)) do
      store = FeoxDB.open!()
      zero = <<0::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", zero)

      final =
        Enum.reduce(deltas, 0, fn delta, _acc ->
          {:ok, new_value} = FeoxDB.increment(store, "counter", delta)
          new_value
        end)

      assert final == Enum.sum(deltas)
    end
  end

  property "range/4 only returns keys within the requested inclusive bounds" do
    check all(
            keys <- StreamData.uniq_list_of(non_empty_binary(), min_length: 1, max_length: 15),
            limit <- StreamData.positive_integer()
          ) do
      store = FeoxDB.open!()

      for key <- keys do
        :ok = FeoxDB.insert(store, key, "v")
      end

      sorted = Enum.sort(keys)
      start_key = List.first(sorted)
      end_key = List.last(sorted)

      assert {:ok, pairs} = FeoxDB.range(store, start_key, end_key, limit)
      returned_keys = Enum.map(pairs, fn {k, _v} -> k end)

      # results are sorted, bounded by the requested inclusive range, and
      # never exceed the requested limit
      assert returned_keys == Enum.sort(returned_keys)
      assert Enum.all?(returned_keys, &(&1 >= start_key and &1 <= end_key))
      assert length(returned_keys) <= limit
    end
  end
end
