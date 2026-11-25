# feoxdb-ex

Use [FeOxDB](https://feoxdb.com) to store binary keys and values in an
Elixir application. The store runs in the same VM as your application.
Keep data in memory or give the store a file path to keep data across restarts.

## Installation

Add the Hex package to the dependencies in `mix.exs`:

```elixir
{:feox_db, "~> 0.2.0"}
```

Run `mix deps.get`. On supported targets, RustlerPrecompiled downloads the
native library during compilation and checks it against the package checksum.
To build from source, install Rust, add `{:rustler, ">= 0.0.0"}` to your
dependencies, and set `FEOXDB_BUILD=true` when compiling.

## Store binary data

```elixir
{:ok, store} = FeoxDB.open()
:ok = FeoxDB.insert(store, "user:1", "Ada")
{:ok, "Ada"} = FeoxDB.get(store, "user:1")
:ok = FeoxDB.close(store)
```

Keys can contain up to 100 KiB. Each value can contain up to 4 MiB.

### Keep data on disk

Pass a file path to `open/1`. The store writes to disk in the background.
A crash can lose buffered writes. Call `flush/1` to wait for them to reach disk.

```elixir
{:ok, store} = FeoxDB.open(path: "app.feox")
:ok = FeoxDB.insert(store, "user:1", "Ada")
:ok = FeoxDB.flush(store)
:ok = FeoxDB.close(store)
```

Close the store when you finish. Closing releases its native resources,
including file handles and background workers, after active calls finish.

### Store Erlang terms

Use `FeoxDB.Term` for term keys and values. It splits large encoded values
into records and reassembles them on read. Reserve a separate store for
terms because raw binary keys can overwrite its internal records.

```elixir
{:ok, store} = FeoxDB.open()
:ok = FeoxDB.Term.put(store, {:user, 1}, %{name: "Ada"})
{:ok, %{name: "Ada"}} = FeoxDB.Term.get(store, {:user, 1})
:ok = FeoxDB.close(store)
```

## Benchmarks

The [benchmark report](bench/REPORT.md) compares FeOxDB with ETS, Cachex,
DETS, Mnesia, and CubDB. The run used 20,000 keys and 64-byte values.
All persistent stores used a RAM-backed filesystem (tmpfs).

## License

MIT
