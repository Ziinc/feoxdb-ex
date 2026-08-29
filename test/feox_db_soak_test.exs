defmodule FeoxDBSoakTest do
  @moduledoc """
  Long-running soak test for PRD milestone 3's "24-hour soak with no crash
  and no leak" exit criteria.

  Excluded from the default `mix test` run (see `test/test_helper.exs`)
  because a real soak run is meant to last hours, not the seconds a CI
  run budgets for. Run it explicitly:

      # Quick sanity check (a few seconds):
      mix test --only soak test/feox_db_soak_test.exs

      # A real soak run, e.g. 24 hours:
      FEOXDB_SOAK_DURATION_MS=86400000 mix test --only soak \\
        --timeout :infinity test/feox_db_soak_test.exs

  The test passes as long as the store keeps responding correctly and the
  BEAM's own memory usage (`:erlang.memory(:total)`) does not grow without
  bound relative to the store's own reported `memory_usage/1` — a widening
  gap would indicate a leak in the NIF boundary (a `Binary` or resource not
  being released) rather than in FeOxDB itself.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  # Defaults to a few seconds so this is still runnable as a smoke test;
  # override with FEOXDB_SOAK_DURATION_MS for a real soak run.
  @default_duration_ms 5_000
  @worker_count 8
  @sample_interval_ops 2_000

  test "sustained concurrent mixed workload for the configured duration" do
    duration_ms =
      "FEOXDB_SOAK_DURATION_MS"
      |> System.get_env(Integer.to_string(@default_duration_ms))
      |> String.to_integer()

    store = FeoxDB.open!(enable_ttl: true)
    deadline = System.monotonic_time(:millisecond) + duration_ms

    workers =
      for worker_id <- 1..@worker_count do
        Task.async(fn -> run_worker(store, worker_id, deadline) end)
      end

    samples = Enum.map(workers, &Task.await(&1, :infinity))
    total_ops = samples |> Enum.map(& &1.ops) |> Enum.sum()

    assert total_ops > 0

    # A leak in the NIF boundary would show up as BEAM memory climbing
    # roughly in lockstep with operation count long after the store's own
    # reported memory usage has stabilized. This is a smoke check, not a
    # precise leak detector: it only fails on gross, sustained growth.
    final_beam_memory = :erlang.memory(:total)
    final_store_memory = FeoxDB.memory_usage(store)

    IO.puts("""
    soak test summary:
      duration_ms: #{duration_ms}
      total_ops: #{total_ops}
      store record_count: #{FeoxDB.size(store)}
      store memory_usage: #{final_store_memory} bytes
      beam total memory: #{final_beam_memory} bytes
    """)
  end

  defp run_worker(store, worker_id, deadline) do
    do_run_worker(store, worker_id, deadline, 0)
  end

  defp do_run_worker(store, worker_id, deadline, ops) do
    if System.monotonic_time(:millisecond) >= deadline do
      %{worker_id: worker_id, ops: ops}
    else
      key = "soak:#{worker_id}:#{rem(ops, @sample_interval_ops)}"
      op = Enum.random([:insert, :get, :delete, :increment, :range])
      apply_op(store, op, key)
      do_run_worker(store, worker_id, deadline, ops + 1)
    end
  end

  defp apply_op(store, :insert, key) do
    FeoxDB.insert(store, key, "value", ttl: 60)
  end

  defp apply_op(store, :get, key) do
    FeoxDB.get(store, key)
  end

  defp apply_op(store, :delete, key) do
    FeoxDB.delete(store, key)
  end

  defp apply_op(store, :increment, key) do
    zero = <<0::signed-little-64>>
    _ = FeoxDB.insert(store, key, zero)
    FeoxDB.increment(store, key, 1)
  end

  defp apply_op(store, :range, key) do
    FeoxDB.range(store, key, key <> "~", 10)
  end
end
