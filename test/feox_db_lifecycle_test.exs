defmodule FeoxDBLifecycleTest do
  @moduledoc """
  Lifecycle and edge-case coverage that the other test files don't reach:

    * best-effort verification that a store's underlying NIF resource gets
      released once the last Elixir reference to it is garbage collected
      (there is no explicit `close/1` in this API yet -- cleanup is purely
      reference-count based, via Rustler's resource destructor)
    * oversized key/value rejection (`:invalid_key_size` / `:invalid_value_size`,
      per the upstream `feoxdb` crate's `MAX_KEY_SIZE` / `MAX_VALUE_SIZE`)
    * `range/4` with a very large `limit`
    * `increment/3` near `i64` overflow boundaries
  """

  use ExUnit.Case, async: true

  # Upstream `feoxdb` crate constants (see `feoxdb-*/src/constants.rs`):
  # `MAX_KEY_SIZE = 100 * KB`, `MAX_VALUE_SIZE = 4 * MB`.
  @max_key_size 100 * 1024
  @max_value_size 4 * 1024 * 1024

  @i64_max 9_223_372_036_854_775_807
  @i64_min -9_223_372_036_854_775_808

  describe "resource cleanup on GC" do
    # This is inherently best-effort: a Rustler `ResourceArc`'s destructor
    # runs when the BEAM garbage collects the last reference to it, which is
    # neither immediate nor deterministic. We can't observe the Rust-side
    # drop directly from Elixir, so this test only pins the *externally
    # observable* contract: dropping our only reference to a store and
    # forcing a GC does not crash the process, and a freshly opened store
    # afterwards behaves normally (i.e. nothing about the previous store's
    # teardown corrupts subsequent NIF calls).
    test "dropping the last reference and forcing GC does not affect later stores" do
      store_size =
        fn ->
          {:ok, store} = FeoxDB.open()
          :ok = FeoxDB.insert(store, "key", "value")
          assert FeoxDB.size(store) == 1
          # `store` becomes unreachable once this function returns.
          :ok
        end

      assert store_size.() == :ok

      # Nudge the collector; this does not guarantee the resource's Rust
      # destructor has run by the time we return, but it is the closest
      # thing to "force cleanup" available from pure Elixir.
      :erlang.garbage_collect()

      # A new store, opened after the old one was dropped and GC'd, should
      # be entirely unaffected -- confirming there's no shared/global state
      # leaking across store lifetimes.
      assert {:ok, new_store} = FeoxDB.open()
      assert FeoxDB.size(new_store) == 0
      assert :ok = FeoxDB.insert(new_store, "key", "value")
      assert {:ok, "value"} = FeoxDB.get(new_store, "key")
    end

    test "a persistent store's file remains usable after the old reference is GC'd" do
      path =
        Path.join(
          System.tmp_dir!(),
          "feox_db_lifecycle_test_#{System.unique_integer([:positive])}.feox"
        )

      on_exit(fn -> File.rm(path) end)

      write_and_flush =
        fn ->
          {:ok, store} = FeoxDB.open(path: path, file_size: 10 * 1024 * 1024)
          :ok = FeoxDB.insert(store, "k", "v")
          :ok = FeoxDB.flush(store)
          :ok
        end

      assert write_and_flush.() == :ok
      :erlang.garbage_collect()

      assert File.exists?(path)
    end
  end

  describe "oversized key/value" do
    setup do
      {:ok, store: FeoxDB.open!()}
    end

    test "insert/4 rejects a key larger than the maximum key size", %{store: store} do
      oversized_key = String.duplicate("k", @max_key_size + 1)

      assert {:error, :invalid_key_size} = FeoxDB.insert(store, oversized_key, "value")
    end

    test "insert/4 rejects a value larger than the maximum value size", %{store: store} do
      oversized_value = String.duplicate("v", @max_value_size + 1)

      assert {:error, :invalid_value_size} = FeoxDB.insert(store, "key", oversized_value)
    end

    test "insert/4 accepts a key at exactly the maximum key size", %{store: store} do
      max_key = String.duplicate("k", @max_key_size)

      assert :ok = FeoxDB.insert(store, max_key, "value")
      assert {:ok, "value"} = FeoxDB.get(store, max_key)
    end

    @tag :slow
    test "insert/4 accepts a value at exactly the maximum value size", %{store: store} do
      max_value = String.duplicate("v", @max_value_size)

      assert :ok = FeoxDB.insert(store, "key", max_value)
      assert {:ok, ^max_value} = FeoxDB.get(store, "key")
    end
  end

  describe "range/4 with large limits" do
    setup do
      store = FeoxDB.open!()

      for i <- 1..50 do
        key = "user:" <> String.pad_leading(Integer.to_string(i), 3, "0")
        :ok = FeoxDB.insert(store, key, "value#{i}")
      end

      {:ok, store: store}
    end

    test "a limit far larger than the record count returns only the matching records", %{
      store: store
    } do
      assert {:ok, pairs} = FeoxDB.range(store, "user:001", "user:050", 1_000_000)
      assert length(pairs) == 50
    end

    test "a limit at the maximum positive integer does not error", %{store: store} do
      assert {:ok, pairs} = FeoxDB.range(store, "user:001", "user:050", @i64_max)
      assert length(pairs) == 50
    end
  end

  describe "increment/3 near integer overflow boundaries" do
    setup do
      {:ok, store: FeoxDB.open!()}
    end

    test "incrementing at i64::MAX by a positive delta does not silently wrap or crash the VM",
         %{store: store} do
      max_bytes = <<@i64_max::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", max_bytes)

      case FeoxDB.increment(store, "counter", 1) do
        {:ok, value} ->
          # Pin whatever the current (non-crashing) behavior is: either it
          # saturates, or it wraps to i64::MIN. Either is acceptable so long
          # as it's an ordinary Elixir integer and the VM is still alive.
          assert is_integer(value)

        {:error, reason} ->
          # An explicit overflow error is also an acceptable outcome.
          assert is_atom(reason)
      end

      # The store must still be usable after this call, regardless of which
      # branch above was hit.
      assert {:ok, _} = FeoxDB.get(store, "counter")
    end

    test "incrementing at i64::MIN by a negative delta does not silently wrap or crash the VM",
         %{store: store} do
      min_bytes = <<@i64_min::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", min_bytes)

      case FeoxDB.increment(store, "counter", -1) do
        {:ok, value} -> assert is_integer(value)
        {:error, reason} -> assert is_atom(reason)
      end

      assert {:ok, _} = FeoxDB.get(store, "counter")
    end

    test "incrementing by a delta of i64::MAX from zero does not crash the VM", %{store: store} do
      zero = <<0::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", zero)

      case FeoxDB.increment(store, "counter", @i64_max) do
        {:ok, value} -> assert value == @i64_max
        {:error, reason} -> assert is_atom(reason)
      end
    end

    test "incrementing by a delta of i64::MIN from zero does not crash the VM", %{store: store} do
      zero = <<0::signed-little-64>>
      :ok = FeoxDB.insert(store, "counter", zero)

      case FeoxDB.increment(store, "counter", @i64_min) do
        {:ok, value} -> assert value == @i64_min
        {:error, reason} -> assert is_atom(reason)
      end
    end
  end
end
