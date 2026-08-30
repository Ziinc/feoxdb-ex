defmodule FeoxDBTest do
  use ExUnit.Case, async: true

  describe "open/1" do
    test "opens a memory-only store with no options" do
      assert {:ok, store} = FeoxDB.open()
      assert FeoxDB.size(store) == 0
    end

    test "opens a persistent store given a path" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      assert {:ok, store} = FeoxDB.open(path: path, file_size: 10 * 1024 * 1024)
      assert :ok = FeoxDB.insert(store, "k", "v")
      assert :ok = FeoxDB.flush(store)
      assert {:ok, "v"} = FeoxDB.get(store, "k")
    end

    test "rejects an invalid hash_bits value" do
      assert_raise ArgumentError, fn -> FeoxDB.open(hash_bits: -1) end
    end

    test "rejects an invalid max_memory value" do
      assert_raise ArgumentError, fn -> FeoxDB.open(max_memory: "lots") end
    end

    test "open!/1 returns the store directly" do
      assert is_reference(FeoxDB.open!())
    end
  end

  describe "get/2, insert/4, delete/2" do
    setup do
      {:ok, store: FeoxDB.open!()}
    end

    test "round-trips a value", %{store: store} do
      assert :ok = FeoxDB.insert(store, "key", "value")
      assert {:ok, "value"} = FeoxDB.get(store, "key")
    end

    test "get/2 returns :not_found for a missing key", %{store: store} do
      assert {:error, :not_found} = FeoxDB.get(store, "missing")
    end

    test "get!/2 raises FeoxDB.Error for a missing key", %{store: store} do
      assert_raise FeoxDB.Error, fn -> FeoxDB.get!(store, "missing") end
    end

    test "insert!/4 raises nothing on success", %{store: store} do
      assert :ok = FeoxDB.insert!(store, "key", "value")
    end

    test "delete/2 removes a key", %{store: store} do
      :ok = FeoxDB.insert(store, "key", "value")
      assert :ok = FeoxDB.delete(store, "key")
      assert {:error, :not_found} = FeoxDB.get(store, "key")
    end

    test "delete/2 on a missing key returns :not_found", %{store: store} do
      assert {:error, :not_found} = FeoxDB.delete(store, "missing")
    end
  end

  describe "member?/2, size/1, memory_usage/1" do
    setup do
      {:ok, store: FeoxDB.open!()}
    end

    test "member?/2 reflects presence", %{store: store} do
      refute FeoxDB.member?(store, "key")
      :ok = FeoxDB.insert(store, "key", "value")
      assert FeoxDB.member?(store, "key")
    end

    test "size/1 counts records", %{store: store} do
      assert FeoxDB.size(store) == 0
      :ok = FeoxDB.insert(store, "a", "1")
      :ok = FeoxDB.insert(store, "b", "2")
      assert FeoxDB.size(store) == 2
    end

    test "memory_usage/1 grows after inserts", %{store: store} do
      before = FeoxDB.memory_usage(store)
      :ok = FeoxDB.insert(store, "key", String.duplicate("x", 1024))
      assert FeoxDB.memory_usage(store) > before
    end
  end

  describe "range/4" do
    setup do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, "user:001", "Alice")
      :ok = FeoxDB.insert(store, "user:002", "Bob")
      :ok = FeoxDB.insert(store, "user:003", "Charlie")
      {:ok, store: store}
    end

    test "returns keys within the inclusive range", %{store: store} do
      assert {:ok, pairs} = FeoxDB.range(store, "user:001", "user:003", 10)

      assert pairs == [
               {"user:001", "Alice"},
               {"user:002", "Bob"},
               {"user:003", "Charlie"}
             ]
    end

    test "respects the limit", %{store: store} do
      assert {:ok, pairs} = FeoxDB.range(store, "user:001", "user:003", 2)
      assert length(pairs) == 2
    end

    test "allows a limit at the maximum", %{store: store} do
      assert {:ok, _pairs} = FeoxDB.range(store, "user:001", "user:003", 10_000)
    end

    test "rejects a limit above the maximum", %{store: store} do
      assert {:error, :limit_too_large} = FeoxDB.range(store, "user:001", "user:003", 10_001)
    end
  end

  describe "TTL" do
    setup do
      {:ok, store: FeoxDB.open!(enable_ttl: true)}
    end

    test "insert/4 with :ttl sets an expiry", %{store: store} do
      :ok = FeoxDB.insert(store, "key", "value", ttl: 60)
      assert {:ok, seconds} = FeoxDB.ttl(store, "key")
      assert is_integer(seconds) and seconds > 0
    end

    test "a key without TTL returns {:ok, nil}", %{store: store} do
      :ok = FeoxDB.insert(store, "key", "value")
      assert {:ok, nil} = FeoxDB.ttl(store, "key")
    end

    test "update_ttl/3 changes the expiry", %{store: store} do
      :ok = FeoxDB.insert(store, "key", "value", ttl: 60)
      assert :ok = FeoxDB.update_ttl(store, "key", 120)
      assert {:ok, seconds} = FeoxDB.ttl(store, "key")
      assert seconds > 60
    end

    test "persist/2 removes the expiry", %{store: store} do
      :ok = FeoxDB.insert(store, "key", "value", ttl: 60)
      assert :ok = FeoxDB.persist(store, "key")
      assert {:ok, nil} = FeoxDB.ttl(store, "key")
    end

    test "TTL operations error without enable_ttl" do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, "key", "value")
      assert {:error, :ttl_not_enabled} = FeoxDB.update_ttl(store, "key", 60)
    end
  end

  describe "atomics" do
    setup do
      {:ok, store: FeoxDB.open!()}
    end

    test "increment/3 creates and updates a counter", %{store: store} do
      zero = <<0::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", zero)
      assert {:ok, 1} = FeoxDB.increment(store, "counter", 1)
      assert {:ok, 6} = FeoxDB.increment(store, "counter", 5)
      assert {:ok, 4} = FeoxDB.increment(store, "counter", -2)
    end

    test "compare_and_swap/4 only swaps on match", %{store: store} do
      :ok = FeoxDB.insert(store, "config", "v1")
      assert {:ok, true} = FeoxDB.compare_and_swap(store, "config", "v1", "v2")
      assert {:ok, false} = FeoxDB.compare_and_swap(store, "config", "v1", "v3")
      assert {:ok, "v2"} = FeoxDB.get(store, "config")
    end
  end

  describe "json_patch/3" do
    test "applies an RFC 6902 patch" do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, "doc", ~s({"a":1}))

      assert :ok =
               FeoxDB.json_patch(
                 store,
                 "doc",
                 ~s([{"op":"replace","path":"/a","value":2}])
               )

      assert {:ok, ~s({"a":2})} = FeoxDB.get(store, "doc")
    end
  end

  describe "stats/1" do
    test "returns a map of counters" do
      store = FeoxDB.open!()
      :ok = FeoxDB.insert(store, "key", "value")
      {:ok, _} = FeoxDB.get(store, "key")

      stats = FeoxDB.stats(store)
      assert is_map(stats)
      assert stats.record_count == 1
      assert stats.total_inserts == 1
      assert stats.total_gets == 1
    end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "feox_db_test_#{System.unique_integer([:positive])}.feox")
  end
end
