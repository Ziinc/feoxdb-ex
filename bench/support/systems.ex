defmodule Bench.System do
  @moduledoc """
  A tiny adapter so `bench/run.exs` can drive `feoxdb_ex` and the other
  stores through the same shape (PRD section 9.1). Every adapter returns
  the same normalized results so the harness can assert on them:

    * `get/2` -> `{:ok, value}` or `{:error, :not_found}`
    * `insert/3`, `delete/2` -> `:ok` (anything else is a failed operation)
  """

  @callback open(opts :: keyword()) :: term()
  @callback get(handle :: term(), key :: binary()) :: {:ok, binary()} | {:error, :not_found}
  @callback insert(handle :: term(), key :: binary(), value :: binary()) :: :ok | term()
  @callback delete(handle :: term(), key :: binary()) :: :ok | term()
  @callback flush(handle :: term()) :: :ok | term()
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
  def close(store), do: FeoxDB.close(store)
end

defmodule Bench.System.FeoxPersistent do
  @moduledoc """
  feoxdb_ex, persistent mode. Writes are buffered and persisted by
  background writer threads; `flush/1` is only called after preload, so
  no measured workload pays for making writes durable.
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
  def close(store), do: FeoxDB.close(store)
end

defmodule Bench.System.CubDB do
  @moduledoc """
  CubDB with `auto_file_sync: true`, which fsyncs after every write. This
  is a stronger durability setting than the other disk-backed systems,
  none of which sync per write (PRD section 9.7: state it, don't hide it).
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
  def get(pid, key) do
    case CubDB.fetch(pid, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

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
  def insert({name, _pid}, key, value) do
    case Cachex.put(name, key, value) do
      {:ok, true} -> :ok
      other -> other
    end
  end

  @impl true
  def delete({name, _pid}, key) do
    case Cachex.del(name, key) do
      {:ok, true} -> :ok
      other -> other
    end
  end

  @impl true
  def flush(_handle), do: :ok

  @impl true
  def close({_name, pid}), do: Supervisor.stop(pid)
end

defmodule Bench.System.Dets do
  @moduledoc """
  `:dets`, the BEAM's built-in disk-based term store. Writes are buffered
  and not synced per write (`flush/1` calls `:dets.sync/1`).
  """
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
  def insert(table, key, value), do: :dets.insert(table, {key, value})

  @impl true
  def delete(table, key), do: :dets.delete(table, key)

  @impl true
  def flush(table), do: :dets.sync(table)

  @impl true
  def close(table), do: :dets.close(table)
end

defmodule Bench.System.Mnesia do
  @moduledoc """
  `:mnesia` with a `disc_copies` table, driven through the `dirty_*` API:
  the whole table lives in RAM and writes go to a transaction log that is
  dumped to disk in the background, without a transaction or per-write
  sync.
  """
  @behaviour Bench.System

  @impl true
  def open(opts) do
    table = Keyword.fetch!(opts, :table)
    dir = Keyword.fetch!(opts, :dir)
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    # The data directory is only read from the application env at start-up;
    # `create_schema/2` has no `dir` option.
    :stopped = :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    :ok = :mnesia.create_schema([node()])
    :ok = :mnesia.start()
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
  def insert(table, key, value), do: :mnesia.dirty_write({table, key, value})

  @impl true
  def delete(table, key), do: :mnesia.dirty_delete(table, key)

  @impl true
  def flush(_table), do: :ok

  @impl true
  def close(table) do
    {:atomic, :ok} = :mnesia.delete_table(table)
    :stopped = :mnesia.stop()
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
    true = :ets.insert(table, {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    true = :ets.delete(table, key)
    :ok
  end

  @impl true
  def flush(_table), do: :ok

  @impl true
  def close(table), do: :ets.delete(table)
end
