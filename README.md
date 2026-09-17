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

Preliminary, single-container numbers (median latency, `parallel: 1`,
20K keys / 64B values) from `bench/run.exs` — not a substitute for a
dedicated-hardware run. See [`bench/REPORT.md`](bench/REPORT.md) for
full methodology and caveats.

### Memory-backed

| Workload | `:ets` | feox_memory | cachex |
|---|---|---|---|
| Random read | 79.8 μs | 87.3 μs | 83.0 μs |
| Write only | 1.27 μs | 5.48 μs | 1.85 μs |
| Mixed 80/20 | 77.9 μs | 86.0 μs | 79.3 μs |
| Delete | 0.23 μs | 2.87 μs | 0.69 μs |

`feoxdb_ex` (memory mode) tracks raw `:ets` reasonably closely across
all four workloads.

### Disk-backed

| Workload | feox_persistent | dets | mnesia (disc_copies) | cubdb |
|---|---|---|---|---|
| Random read | 95.9 μs | 113.7 μs | 79.8 μs | 185.3 μs |
| Write only | 24.8 μs | 2.28 μs | 3.60 μs | 233.4 μs |
| Mixed 80/20 | 86.7 μs | 118.8 μs | 88.2 μs | 202.7 μs |
| Delete | 3.05 μs | 1.98 μs | 2.04 μs | 183.3 μs |

`feoxdb_ex` (persistent mode) stays well ahead of CubDB across the
board; `mnesia` here is its cheapest, least-safe `dirty_*` API, not a
transactional comparison. `feox_persistent`'s write-only number is
affected by write-buffer backpressure under sustained load, and
`dets`'s own write buffering shows up as a long tail rather than in its
median (see the report for details).

## License

MIT

