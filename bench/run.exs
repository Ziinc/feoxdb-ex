# Benchmark harness for PRD section 9.
#
# Run with `MIX_ENV=bench mix run bench/run.exs`. See bench/README.md for
# the full set of environment variables and what they control, and for
# why the defaults here are a small "smoke scale" run rather than the
# PRD's full 1M-key / 5-concurrency-level / 3-value-size matrix.
Code.require_file("support/systems.ex", __DIR__)

defmodule Bench.Run do
  @moduledoc false

  defp systems do
    [
      {"cachex", Bench.System.Cachex, [name: :bench_cache]},
      {"cubdb", Bench.System.CubDB, [path: Path.join(bench_tmp_dir(), "cubdb_bench")]},
      {"dets", Bench.System.Dets,
       [name: :bench_dets, path: Path.join(bench_tmp_dir(), "dets_bench.dets")]},
      {"ets", Bench.System.Ets, [name: :bench_ets]},
      {"feox_memory", Bench.System.FeoxMemory, []},
      {"feox_persistent", Bench.System.FeoxPersistent,
       [path: Path.join(bench_tmp_dir(), "feoxdb_bench.feox")]},
      {"mnesia", Bench.System.Mnesia,
       [table: :bench_mnesia, dir: Path.join(bench_tmp_dir(), "mnesia_bench")]}
    ]
  end

  def dataset_size, do: env_int("BENCH_DATASET_SIZE", 5_000)
  def value_size, do: env_int("BENCH_VALUE_SIZE", 64)
  def concurrency_levels, do: env_int_list("BENCH_CONCURRENCY", [1, 8])
  def bench_time, do: env_float("BENCH_TIME_S", 2.0)
  def warmup_time, do: env_float("BENCH_WARMUP_S", 1.0)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp env_float(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> Float.parse() |> elem(0)
    end
  end

  defp env_int_list(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.split(",") |> Enum.map(&String.to_integer/1)
    end
  end

  # Prefer tmpfs when available: the persistent-mode scenarios push enough
  # write volume that a slow disk (an overlay filesystem in a container,
  # say) causes FeOxDB's write buffer to back up and log retry warnings,
  # which is noisy without being a meaningful part of what's measured here.
  defp bench_tmp_dir do
    if File.dir?("/dev/shm"), do: "/dev/shm", else: System.tmp_dir!()
  end

  def value(size), do: :crypto.strong_rand_bytes(size)

  # A tuple, not a list: picking a random element of a 20K-element list
  # walks the list and costs ~80μs, which would swamp the stores' own
  # sub-μs to few-μs operations.
  def keys(count), do: List.to_tuple(for(i <- 1..count, do: "key:" <> Integer.to_string(i)))

  def random_key(keys), do: elem(keys, :rand.uniform(tuple_size(keys)) - 1)

  def preload(mod, handle, keys, value) do
    keys = Tuple.to_list(keys)
    Enum.each(keys, fn key -> :ok = mod.insert(handle, key, value) end)
    :ok = mod.flush(handle)

    # Fail loudly rather than benchmark a store that silently dropped data.
    Enum.each(keys, fn key -> {:ok, ^value} = mod.get(handle, key) end)
  end

  @doc """
  Runs one scenario with every system measured in isolation: each system
  is opened, prepared, measured, and closed before the next one is
  opened, so no other store's background work (write-behind flushing,
  log dumping) competes with it. The per-system results are merged into
  a single suite so the formatters still print one comparison.

  `prepare` runs (unmeasured) after open; `job` returns the Benchee job,
  either a function or a `{function, hooks}` tuple.
  """
  def run(scenario_name, parallel, prepare, job) do
    base =
      [
        time: bench_time(),
        warmup: warmup_time(),
        parallel: parallel,
        memory_time: 1,
        reduction_time: 1,
        print: [configuration: false],
        formatters: [
          {Benchee.Formatters.HTML,
           file: Path.join([__DIR__, "output", "#{scenario_name}_p#{parallel}.html"]),
           auto_open: false},
          Benchee.Formatters.Console
        ],
        title: "#{scenario_name} (parallel: #{parallel})"
      ]
      |> Benchee.init()
      |> Benchee.system()

    scenarios =
      Enum.flat_map(systems(), fn {name, mod, opts} ->
        handle = mod.open(opts)

        try do
          prepare.(mod, handle)

          base
          |> Benchee.benchmark(name, job.(mod, handle))
          |> Benchee.collect()
          |> Map.fetch!(:scenarios)
        after
          mod.close(handle)
        end
      end)

    %{base | scenarios: scenarios}
    |> Benchee.statistics()
    |> Benchee.relative_statistics()
    |> Benchee.Formatter.output()
  end
end

File.mkdir_p!(Path.join(__DIR__, "output"))

alias Bench.Run

keys = Run.keys(Run.dataset_size())
value = Run.value(Run.value_size())
preload = fn mod, handle -> Run.preload(mod, handle, keys, value) end
no_prepare = fn _mod, _handle -> :ok end

IO.puts("""
Benchmark configuration:
  dataset_size: #{Run.dataset_size()}
  value_size:   #{Run.value_size()} bytes
  concurrency:  #{inspect(Run.concurrency_levels())}
  time/warmup:  #{Run.bench_time()}s / #{Run.warmup_time()}s

This is a smoke-scale run, not the PRD section 9.6 dedicated-hardware
benchmark. See bench/README.md before treating these numbers as final.
""")

# Every measured call asserts its result, so a failing operation (a full
# write buffer, a closed store) crashes the run instead of being counted
# as a fast success.
for parallel <- Run.concurrency_levels() do
  # --- Random read (workload 2) ---
  Run.run("random_read", parallel, preload, fn mod, handle ->
    fn -> {:ok, _} = mod.get(handle, Run.random_key(keys)) end
  end)

  # --- Write only (workload 4) ---
  #
  # Every iteration inserts a brand-new key, so the table keeps growing
  # during measurement, and faster systems end up larger than slower ones.
  Run.run("write_only", parallel, no_prepare, fn mod, handle ->
    fn ->
      key = "write:" <> Integer.to_string(System.unique_integer([:positive]))
      :ok = mod.insert(handle, key, value)
    end
  end)

  # --- Mixed 80/20 (workload 6) ---
  Run.run("mixed_80_20", parallel, preload, fn mod, handle ->
    fn ->
      if :rand.uniform(100) <= 80 do
        {:ok, _} = mod.get(handle, Run.random_key(keys))
      else
        :ok = mod.insert(handle, Run.random_key(keys), value)
      end
    end
  end)

  # --- Delete (workload 8) ---
  #
  # The PRD's "remove all preloaded keys" is a bounded, one-shot workload,
  # not a steady-state throughput one. To still let Benchee iterate this
  # scenario for its full measurement window, each iteration re-inserts a
  # fresh key via `:before_each` and then deletes exactly that key, so
  # every measured delete is always removing a key that genuinely exists.
  Run.run("delete", parallel, no_prepare, fn mod, handle ->
    {
      fn key -> :ok = mod.delete(handle, key) end,
      before_each: fn _ ->
        key = "delete:" <> Integer.to_string(System.unique_integer([:positive]))
        :ok = mod.insert(handle, key, value)
        key
      end
    }
  end)
end
