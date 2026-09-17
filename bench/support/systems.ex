defmodule Bench.System do
  @moduledoc """
  A tiny adapter so `bench/run.exs` can drive `feoxdb_ex`, CubDB, Cachex,
  and raw `:ets` through the same shape (PRD section 9.1). Each adapter
  returns an opaque `handle` that `get/3`, `insert/4`, and `delete/3`
  thread back in, so the benchmark code doesn't need to know which store
  it's talking to.
  """

  @callback open(opts :: keyword()) :: term()
  @callback get(handle :: term(), key :: binary()) :: any()
  @callback insert(handle :: term(), key :: binary(), value :: binary()) :: any()
  @callback delete(handle :: term(), key :: binary()) :: any()
  @callback flush(handle :: term()) :: any()
  @callback close(handle :: term()) :: any()
end

defmodule Bench.System.FeoxMemory do
  @moduledoc "feoxdb_ex, memory-only mode."
  @behaviour Bench.System

  @impl true
  def open(_opts), do: FeoxDB.open!()

  @impl true
  def get(store, key), do: FeoxDB.get(store, key)

  @impl true
  def insert(store, key, value), do: FeoxDB.insert(store, key, value)

  @impl true
  def delete(store, key), do: FeoxDB.delete(store, key)

  @impl true
  def flush(_store), do: :ok

  @impl true
  def close(_store), do: :ok
end

defmodule Bench.System.FeoxPersistent do
  @moduledoc """
  feoxdb_ex, persistent mode. Per PRD section 9.7 fairness rules, the
  `:flush` variant of each workload calls `flush/1` explicitly so the
  background write time is counted rather than given away for free.
  """
  @behaviour Bench.System

  @impl true
  def open(opts) do
    path = Keyword.fetch!(opts, :path)
    File.rm(path)
    FeoxDB.open!(path: path, file_size: 256 * 1024 * 1024)
  end

  @impl true
  def get(store, key), do: FeoxDB.get(store, key)

  @impl true
  def insert(store, key, value), do: FeoxDB.insert(store, key, value)

  @impl true
  def delete(store, key), do: FeoxDB.delete(store, key)

  @impl true
  def flush(store), do: FeoxDB.flush(store)

  @impl true
  def close(_store), do: :ok
end

defmodule Bench.System.CubDB do
  @moduledoc """
  CubDB, given an explicit durability setting (PRD section 9.7: don't
  compare a persistent store at its safe default against a native store
  in memory-only mode without saying so).
  """
  @behaviour Bench.System

  @impl true
  def open(opts) do
    path = Keyword.fetch!(opts, :path)
    File.rm_rf(path)
    File.mkdir_p!(path)
    {:ok, pid} = CubDB.start_link(data_dir: path, auto_compact: false, auto_file_sync: true)
    pid
  end

  @impl true
  def get(pid, key), do: CubDB.get(pid, key)

  @impl true
  def insert(pid, key, value), do: CubDB.put(pid, key, value)

  @impl true
  def delete(pid, key), do: CubDB.delete(pid, key)

  @impl true
  def flush(pid), do: CubDB.file_sync(pid)

  @impl true
  def close(pid), do: CubDB.stop(pid)
end

defmodule Bench.System.Cachex do
  @moduledoc "Cachex, in-memory only, included as a non-persistent comparison point."
  @behaviour Bench.System

  @impl true
  def open(opts) do
    name = Keyword.fetch!(opts, :name)
    {:ok, pid} = Cachex.start_link(name)
    {name, pid}
  end

  @impl true
  def get({name, _pid}, key) do
    case Cachex.get(name, key) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, value} -> {:ok, value}
    end
  end

  @impl true
  def insert({name, _pid}, key, value), do: Cachex.put(name, key, value)

  @impl true
  def delete({name, _pid}, key), do: Cachex.del(name, key)

  @impl true
  def flush(_handle), do: :ok

  @impl true
  def close({_name, pid}), do: Supervisor.stop(pid)
end

defmodule Bench.System.Dets do
  @moduledoc "`:dets`, the BEAM's built-in disk-based term store, included as a persistent-mode comparison point."
  @behaviour Bench.System

  @impl true
  def open(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.fetch!(opts, :path)
    File.rm(path)
    {:ok, ^name} = :dets.open_file(name, file: String.to_charlist(path), type: :set)
    name
  end

  @impl true
  def get(table, key) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def insert(table, key, value) do
    :dets.insert(table, {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    :dets.delete(table, key)
    :ok
  end

  @impl true
  def flush(table), do: :dets.sync(table)

  @impl true
  def close(table), do: :dets.close(table)
end

defmodule Bench.System.Mnesia do
  @moduledoc "`:mnesia`, disk_copies mode, included as a persistent-mode comparison point."
  @behaviour Bench.System

  @impl true
  def open(opts) do
    table = Keyword.fetch!(opts, :table)
    dir = Keyword.fetch!(opts, :dir)
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    :application.stop(:mnesia)
    :mnesia.create_schema([node()], dir: String.to_charlist(dir))
    :application.start(:mnesia)
    {:atomic, :ok} = :mnesia.create_table(table, disc_copies: [node()], type: :set)
    table
  end

  @impl true
  def get(table, key) do
    case :mnesia.dirty_read(table, key) do
      [{^table, ^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def insert(table, key, value) do
    :mnesia.dirty_write({table, key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    :mnesia.dirty_delete(table, key)
    :ok
  end

  @impl true
  def flush(_table), do: :ok

  @impl true
  def close(table) do
    :mnesia.delete_table(table)
    :application.stop(:mnesia)
  end
end

defmodule Bench.System.Ets do
  @moduledoc "Raw :ets, the cheapest possible BEAM-native operation (PRD section 9.1 control)."
  @behaviour Bench.System

  @impl true
  def open(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(name, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
  end

  @impl true
  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def insert(table, key, value) do
    :ets.insert(table, {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @impl true
  def flush(_table), do: :ok

  @impl true
  def close(table), do: :ets.delete(table)
end
