# FeoxDB

Elixir bindings for [FeOxDB](https://feoxdb.com), an embedded key-value store
written in Rust that keeps hot data in memory and writes to disk in the
background. See [`docs/PRD.md`](docs/PRD.md) for the full design.

## Status

All 7 PRD milestones have a first pass implemented:

- Full FeOxDB API (lifecycle, basic operations, ranges, TTL, atomics,
  JSON patch, stats) through Rustler, Dialyzer-clean, with published docs.
- Property, concurrency, and soak tests (`mix test`; see
  [Development](#development) below for the soak test).
- CI (`.github/workflows/ci.yml`) and a release workflow
  (`.github/workflows/release.yml`) that builds precompiled NIFs for
  every Tier 1 target (plus best-effort Windows) on a tagged release.
- A Benchee-based benchmark harness comparing `feoxdb_ex` against CubDB,
  Cachex, and raw `:ets` (see [`bench/`](bench)).

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

Building from source requires a Rust toolchain (stable, 2021 edition).

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

See the `FeoxDB` module docs for the full API: ranges, TTL, atomic
increment/compare-and-swap, and RFC 6902 JSON patch.

Keys are limited to 100 KB and values to 4 MB (mirroring the underlying
`feoxdb` Rust crate's internal limits). `FeoxDB` checks these limits in
Elixir before calling into native code and returns
`{:error, :key_too_large}` / `{:error, :value_too_large}` for oversized
input, rather than relying solely on that crate to reject it.

## Development

```
mix deps.get
mix test
```

The Rust crate lives under `native/feoxdb_nif`; `mix compile` builds it
automatically via Rustler.

Other checks used in CI:

```
mix format --check-formatted
cargo fmt --manifest-path native/feoxdb_nif/Cargo.toml -- --check
cargo clippy --manifest-path native/feoxdb_nif/Cargo.toml --release -- -D warnings
mix dialyzer
mix docs
```

The soak test (PRD milestone 3) is excluded from the default `mix test`
run since it's meant to run for hours, not seconds:

```
mix test --only soak test/feox_db_soak_test.exs
FEOXDB_SOAK_DURATION_MS=86400000 mix test --only soak --timeout :infinity test/feox_db_soak_test.exs
```

See [`bench/README.md`](bench/README.md) for the benchmark harness and
[`bench/REPORT.md`](bench/REPORT.md) for the latest results.
