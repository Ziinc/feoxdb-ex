# feoxdb-ex

Elixir bindings for [FeOxDB](https://feoxdb.com), an embedded key-value store
written in Rust that keeps hot data in memory and writes to disk in the
background.

Full FeOxDB API through Rustler precompiled NIFs

Precompiled release artifacts haven't actually been published yet (no
`v*` tag has been pushed), so the NIF still always builds from source —
`FeoxDB.Native` switches to downloading precompiled binaries automatically
once `checksum-Elixir.FeoxDB.Native.exs` exists, which the release
workflow generates on the first tagged release.

## Installation

Add `feox_db` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:feox_db, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
{:ok, store} = FeoxDB.open()
:ok = FeoxDB.insert(store, "key", "value")
{:ok, "value"} = FeoxDB.get(store, "key")
:ok = FeoxDB.close(store)

# Persistent mode
{:ok, store} = FeoxDB.open(path: "/var/lib/app.feox")
:ok = FeoxDB.insert(store, "key", "value")
:ok = FeoxDB.flush(store)
:ok = FeoxDB.close(store)
```

Call `FeoxDB.close/1` once you are done with a store instead of relying on
the garbage collector: it deterministically stops the store's background
writer/TTL sweeper threads and releases its resources, which matters most
for disk-backed stores.

Keys are limited to 100 KB and values to 4 MB (mirroring the underlying
`feoxdb` Rust crate's internal limits).

### Erlang terms and large values

`FeoxDB.Term` stores arbitrary Erlang terms (keys and values) encoded as
ETF, and transparently splits values larger than the 4 MB record limit
into chunks:

```elixir
{:ok, store} = FeoxDB.open()
:ok = FeoxDB.Term.put(store, {:user, 1}, %{name: "Ada"})
{:ok, %{name: "Ada"}} = FeoxDB.Term.get(store, {:user, 1})
:ok = FeoxDB.Term.put(store, :blob, :crypto.strong_rand_bytes(10_000_000))
FeoxDB.Term.stream(store) |> Enum.to_list()
```

A store used through `FeoxDB.Term` should only be accessed through it.


## Benchmarks

Preliminary, single-container numbers (median latency, `parallel: 1`,
20K keys / 64B values) from `bench/run.exs` — not a substitute for a
dedicated-hardware run. See [`bench/REPORT.md`](bench/REPORT.md) for
full methodology and caveats.

### Memory-backed

| Workload | `:ets` | feox_memory | cachex |
|---|---|---|---|
| Random read | 0.59 μs | 4.46 μs | 0.86 μs |
| Write only | 1.11 μs | 3.95 μs | 1.58 μs |
| Mixed 80/20 | 0.62 μs | 4.74 μs | 1.03 μs |
| Delete | 0.19 μs | 3.22 μs | 0.50 μs |

`feoxdb_ex` (memory mode) is several times slower than `:ets` and
Cachex per operation, and the gap widens under concurrency (about 20 μs
per read at `parallel: 4`, against 0.55 μs for `:ets`). Every call
runs on a dirty I/O scheduler, which is the likely cause.

### Disk-backed

| Workload | feox_persistent | dets | mnesia (disc_copies) | cubdb |
|---|---|---|---|---|
| Random read | 4.59 μs | 7.54 μs | 0.56 μs | 92.4 μs |
| Write only | 6.59 μs | 1.37 μs | 2.73 μs | 188.1 μs |
| Mixed 80/20 | 5.82 μs | 8.24 μs | 0.92 μs | 80.6 μs |
| Delete | 3.68 μs | 1.22 μs | 1.61 μs | 88.5 μs |

`feoxdb_ex` (persistent mode) reads faster than `:dets` and CubDB and
is far ahead of CubDB overall. Mnesia is faster still, but only through
its `dirty_*` API, which skips transactions. Durability isn't equal
across this group: CubDB fsyncs every write and the others don't.
`feox_persistent` and `:dets` writes have long tails that medians hide
(99th percentile 429 μs for `feox_persistent`, which logs write-buffer
backpressure under sustained load); see the report for details.

## License

MIT

