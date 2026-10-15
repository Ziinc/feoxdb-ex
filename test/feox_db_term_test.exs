defmodule FeoxDB.TermTest do
  use ExUnit.Case, async: true

  alias FeoxDB.Term

  setup do
    {:ok, store: FeoxDB.open!()}
  end

  test "round-trips arbitrary keys and values", %{store: store} do
    key = {:user, 1, %{"region" => "eu"}}
    value = %{name: "Ada", tags: [:a, :b], at: ~U[2026-01-01 00:00:00Z]}

    assert :ok = Term.put(store, key, value)
    assert {:ok, ^value} = Term.get(store, key)
    assert Term.member?(store, key)
  end

  test "returns :not_found for a missing key", %{store: store} do
    assert {:error, :not_found} = Term.get(store, :missing)
    refute Term.member?(store, :missing)
  end

  test "delete removes the key", %{store: store} do
    :ok = Term.put(store, :k, "v")
    assert :ok = Term.delete(store, :k)
    assert {:error, :not_found} = Term.get(store, :k)
    assert :ok = Term.delete(store, :k)
  end

  describe "chunking" do
    test "transparently stores values larger than the record limit", %{store: store} do
      value = :crypto.strong_rand_bytes(FeoxDB.max_value_size() * 2 + 123)

      assert :ok = Term.put(store, :big, value)
      assert {:ok, ^value} = Term.get(store, :big)
      # manifest + 3 chunks
      assert FeoxDB.size(store) == 4
    end

    test "overwrites remove the previous value's chunks", %{store: store} do
      :ok = Term.put(store, :k, String.duplicate("a", 100), chunk_size: 16)
      assert FeoxDB.size(store) > 2

      :ok = Term.put(store, :k, String.duplicate("b", 50), chunk_size: 16)
      assert {:ok, value} = Term.get(store, :k)
      assert value == String.duplicate("b", 50)
      assert FeoxDB.size(store) == 1 + ceil(byte_size(:erlang.term_to_binary(value)) / 16)

      :ok = Term.put(store, :k, "small")
      assert {:ok, "small"} = Term.get(store, :k)
      assert FeoxDB.size(store) == 1
    end

    test "delete removes every chunk", %{store: store} do
      :ok = Term.put(store, :k, String.duplicate("a", 100), chunk_size: 16)
      assert :ok = Term.delete(store, :k)
      assert FeoxDB.size(store) == 0
    end

    test "a missing chunk reads as :not_found", %{store: store} do
      :ok = Term.put(store, :k, String.duplicate("a", 100), chunk_size: 16)

      {:ok, pairs} = FeoxDB.range(store, <<0>>, <<0, 255>>, 100)
      {chunk_key, _} = hd(pairs)
      :ok = FeoxDB.delete(store, chunk_key)

      assert {:error, :not_found} = Term.get(store, :k)
    end

    test "rejects an invalid chunk_size", %{store: store} do
      assert_raise ArgumentError, fn -> Term.put(store, :k, "v", chunk_size: 0) end

      assert_raise ArgumentError, fn ->
        Term.put(store, :k, "v", chunk_size: FeoxDB.max_value_size() + 1)
      end
    end
  end

  test "stream yields every pair across pages and skips chunk records", %{store: store} do
    for i <- 1..2_500, do: :ok = Term.put(store, {:k, i}, i)
    :ok = Term.put(store, :big, String.duplicate("x", 200), chunk_size: 32)

    pairs = store |> Term.stream() |> Map.new()

    assert map_size(pairs) == 2_501
    assert pairs[{:k, 1_234}] == 1_234
    assert pairs[:big] == String.duplicate("x", 200)
  end

  test "values survive reopening a persistent store" do
    path = Path.join(System.tmp_dir!(), "feox_term_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    store = FeoxDB.open!(path: path, file_size: 64 * 1024 * 1024)
    big = :crypto.strong_rand_bytes(FeoxDB.max_value_size() + 1)
    :ok = Term.put(store, :big, big)
    :ok = Term.put(store, :small, %{a: 1})
    :ok = FeoxDB.flush(store)
    :ok = FeoxDB.close(store)

    store = FeoxDB.open!(path: path)
    assert {:ok, ^big} = Term.get(store, :big)
    assert {:ok, %{a: 1}} = Term.get(store, :small)
    assert store |> Term.stream() |> Enum.count() == 2
  end

  test "ttl applies to the value and its chunks" do
    store = FeoxDB.open!(enable_ttl: true)
    :ok = Term.put(store, :k, String.duplicate("a", 100), chunk_size: 16, ttl: 60)

    {:ok, pairs} = FeoxDB.range(store, <<0>>, <<0, 255>>, 100)
    assert pairs != []

    for {chunk_key, _} <- pairs do
      assert {:ok, ttl} = FeoxDB.ttl(store, chunk_key)
      assert ttl > 0
    end
  end
end
