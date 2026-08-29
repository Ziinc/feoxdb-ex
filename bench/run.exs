# Benchmark harness for PRD section 9.
#
# Run with `MIX_ENV=bench mix run bench/run.exs`. See bench/README.md for
# the full set of environment variables and what they control, and for
# why the defaults here are a small "smoke scale" run rather than the
# PRD's full 1M-key / 5-concurrency-level / 3-value-size matrix.
Code.require_file("support/systems.ex", __DIR__)

defmodule Bench.Run do
  @moduledoc false

  @systems %{
    "feox_memory" => {Bench.System.FeoxMemory, []},
    "feox_persistent" =>
      {Bench.System.FeoxPersistent, [path: Path.join(System.tmp_dir!(), "feoxdb_bench.feox")]},
    "cubdb" => {Bench.System.CubDB, [path: Path.join(System.tmp_dir!(), "cubdb_bench")]},
    "cachex" => {Bench.System.Cachex, [name: :bench_cache]},
    "ets" => {Bench.System.Ets, [name: :bench_ets]}
  }

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

  def value(size), do: :crypto.strong_rand_bytes(size)

  def keys(count), do: for(i <- 1..count, do: "key:" <> Integer.to_string(i))

  def open_all(opts \\ []) do
    Map.new(@systems, fn {name, {mod, mod_opts}} ->
      {name, {mod, mod.open(Keyword.merge(mod_opts, opts))}}
    end)
  end

  def close_all(handles) do
    Enum.each(handles, fn {_name, {mod, handle}} -> mod.close(handle) end)
  end

  def preload(handles, keys, value) do
    Enum.each(handles, fn {_name, {mod, handle}} ->
      Enum.each(keys, &mod.insert(handle, &1, value))
      mod.flush(handle)
    end)
  end

  def jobs(handles, fun) do
    Map.new(handles, fn {name, {mod, handle}} ->
      {name, fn -> fun.(mod, handle) end}
    end)
  end

  def run(scenario_name, jobs, parallel) do
    Benchee.run(
      jobs,
      time: bench_time(),
      warmup: warmup_time(),
      parallel: parallel,
      memory_time: 1,
      reduction_time: 1,
      formatters: [
        {Benchee.Formatters.HTML,
         file: Path.join([__DIR__, "output", "#{scenario_name}_p#{parallel}.html"]),
         auto_open: false},
        Benchee.Formatters.Console
      ],
      title: "#{scenario_name} (parallel: #{parallel})"
    )
  end
end

File.mkdir_p!(Path.join(__DIR__, "output"))

alias Bench.Run

keys = Run.keys(Run.dataset_size())
value = Run.value(Run.value_size())

IO.puts("""
Benchmark configuration:
  dataset_size: #{Run.dataset_size()}
  value_size:   #{Run.value_size()} bytes
  concurrency:  #{inspect(Run.concurrency_levels())}
  time/warmup:  #{Run.bench_time()}s / #{Run.warmup_time()}s

This is a smoke-scale run, not the PRD section 9.6 dedicated-hardware
benchmark. See bench/README.md before treating these numbers as final.
""")

for parallel <- Run.concurrency_levels() do
  # --- Random read (workload 2) ---
  handles = Run.open_all()
  Run.preload(handles, keys, value)

  jobs =
    Run.jobs(handles, fn mod, handle ->
      key = Enum.random(keys)
      mod.get(handle, key)
    end)

  Run.run("random_read", jobs, parallel)
  Run.close_all(handles)

  # --- Write only (workload 4) ---
  handles = Run.open_all()

  jobs =
    Run.jobs(handles, fn mod, handle ->
      key = "write:" <> Integer.to_string(System.unique_integer([:positive]))
      mod.insert(handle, key, value)
    end)

  Run.run("write_only", jobs, parallel)
  Run.close_all(handles)

  # --- Mixed 80/20 (workload 6) ---
  handles = Run.open_all()
  Run.preload(handles, keys, value)

  jobs =
    Run.jobs(handles, fn mod, handle ->
      if :rand.uniform(100) <= 80 do
        mod.get(handle, Enum.random(keys))
      else
        mod.insert(handle, Enum.random(keys), value)
      end
    end)

  Run.run("mixed_80_20", jobs, parallel)
  Run.close_all(handles)

  # --- Delete (workload 8) ---
  #
  # The PRD's "remove all preloaded keys" is a bounded, one-shot workload,
  # not a steady-state throughput one. To still let Benchee iterate this
  # scenario for its full measurement window, each iteration re-inserts a
  # fresh key via `:before_each` and then deletes exactly that key, so
  # every measured delete is always removing a key that genuinely exists.
  handles = Run.open_all()

  jobs =
    Map.new(handles, fn {name, {mod, handle}} ->
      {name,
       {
         fn key -> mod.delete(handle, key) end,
         before_each: fn _ ->
           key = "delete:" <> Integer.to_string(System.unique_integer([:positive]))
           _ = mod.insert(handle, key, value)
           key
         end
       }}
    end)

  Run.run("delete", jobs, parallel)
  Run.close_all(handles)
end
