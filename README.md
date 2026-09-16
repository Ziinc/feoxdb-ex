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


## Benchmarks

Preliminary, single-container numbers (median latency, 20K keys / 64B
values) from `bench/run.exs` — not a substitute for a dedicated-hardware
run. See [`bench/REPORT.md`](bench/REPORT.md) for full methodology and
caveats.

| Workload | `:ets` | feox_memory | feox_persistent | cachex | cubdb |
|---|---|---|---|---|---|
| Random read | 80.8 μs | 83.3 μs | 88.3 μs | 83.8 μs | 198.5 μs |
| Write only | 1.46 μs | 1.67 μs | 24.5 μs | 2.25 μs | 315.9 μs |
| Mixed 80/20 | 79.6 μs | 87.1 μs | 90.2 μs | 81.1 μs | 209.1 μs |
| Delete | 0.35 μs | 0.59 μs | 0.79 μs | 0.88 μs | 89.7 μs |

`feoxdb_ex` tracks raw `:ets` closely and stays well ahead of CubDB;
`feox_persistent`'s write-only number is affected by write-buffer
backpressure under sustained load (see the report for details).

## License

MIT

