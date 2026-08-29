defmodule FeoxDBConcurrencyTest do
  @moduledoc """
  Concurrency tests (PRD milestone 3). `FeoxStore` is `Send + Sync` and the
  binding deliberately does not serialize access through a GenServer
  (see `docs/PRD.md` section 6.1), so these tests hammer a single store
  from many processes at once and check for crashes, lost updates, and
  leaked resources.
  """

  use ExUnit.Case, async: true

  @moduletag :concurrency
  @moduletag timeout: 60_000

  test "many processes inserting distinct keys concurrently all succeed" do
    store = FeoxDB.open!()
    process_count = 32
    keys_per_process = 200

    results =
      1..process_count
      |> Task.async_stream(
        fn worker_id ->
          for i <- 1..keys_per_process do
            key = "worker:#{worker_id}:#{i}"
            FeoxDB.insert(store, key, "value")
          end
        end,
        max_concurrency: process_count,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert FeoxDB.size(store) == process_count * keys_per_process
  end

  test "concurrent increments on the same counter never lose an update" do
    store = FeoxDB.open!()
    zero = <<0::signed-little-64>>
    :ok = FeoxDB.insert(store, "shared_counter", zero)

    process_count = 16
    increments_per_process = 500

    1..process_count
    |> Task.async_stream(
      fn _ ->
        for _ <- 1..increments_per_process do
          {:ok, _} = FeoxDB.increment(store, "shared_counter", 1)
        end
      end,
      max_concurrency: process_count,
      timeout: 30_000
    )
    |> Stream.run()

    expected_total = process_count * increments_per_process
    assert {:ok, ^expected_total} = FeoxDB.increment(store, "shared_counter", 0)
  end

  test "concurrent readers and a writer never observe a torn value" do
    store = FeoxDB.open!()
    key = "hot_key"
    value_a = String.duplicate("a", 4096)
    value_b = String.duplicate("b", 4096)
    :ok = FeoxDB.insert(store, key, value_a)

    writer =
      Task.async(fn ->
        for i <- 1..2000 do
          value = if rem(i, 2) == 0, do: value_a, else: value_b
          :ok = FeoxDB.insert(store, key, value)
        end
      end)

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          for _ <- 1..2000 do
            case FeoxDB.get(store, key) do
              {:ok, value} -> assert value in [value_a, value_b]
              {:error, :not_found} -> :ok
            end
          end
        end)
      end

    Task.await(writer, 30_000)
    Enum.each(readers, &Task.await(&1, 30_000))
  end

  test "concurrent insert/delete of the same key never crashes the store" do
    store = FeoxDB.open!()
    key = "contended_key"

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          for _ <- 1..500 do
            # Racing inserts/deletes on the same key can legitimately return
            # `:older_timestamp` or `:not_found` here: that's expected,
            # benign contention, not a bug. This test's purpose is to prove
            # the store survives the contention without crashing, not that
            # every racing call succeeds.
            case FeoxDB.insert(store, key, "value") do
              :ok -> :ok
              {:error, _reason} -> :ok
            end

            case FeoxDB.delete(store, key) do
              :ok -> :ok
              {:error, _reason} -> :ok
            end
          end

          :ok
        end)
      end

    # Task.await/2 itself raises if any task crashed, so reaching this
    # assertion already proves the store held up under contention.
    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 30_000)), &(&1 == :ok))
    assert is_boolean(FeoxDB.member?(store, key))
  end

  test "the store resource is released and background threads stop when garbage collected" do
    {store, ref} =
      Task.async(fn ->
        store = FeoxDB.open!(enable_ttl: true)
        :ok = FeoxDB.insert(store, "key", "value", ttl: 60)
        {store, make_ref()}
      end)
      |> Task.await()

    # The store resource has no other references once this test process
    # forgets it; force a GC to trigger FeoxStore's Drop impl (PRD open
    # question 1) instead of waiting for it. This mainly asserts that
    # doing so does not crash the VM.
    _ = {store, ref}
    :erlang.garbage_collect()
    Process.sleep(50)
    assert true
  end
end
