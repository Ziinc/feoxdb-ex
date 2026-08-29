# FeoxDB

Elixir bindings for [FeOxDB](https://feoxdb.com), an embedded key-value store
written in Rust that keeps hot data in memory and writes to disk in the
background. See [`docs/PRD.md`](docs/PRD.md) for the full design.

## Status

Milestone 1 of the PRD: a working skeleton exposing the full FeOxDB API
(lifecycle, basic operations, ranges, TTL, atomics, JSON patch, and stats)
through Rustler, with a passing test suite. Precompiled release artifacts
(PRD section 8) have not been published yet, so the NIF always builds from
source for now.

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

# Persistent mode
{:ok, store} = FeoxDB.open(path: "/var/lib/app.feox")
:ok = FeoxDB.insert(store, "key", "value")
:ok = FeoxDB.flush(store)
```

See the `FeoxDB` module docs for the full API: ranges, TTL, atomic
increment/compare-and-swap, and RFC 6902 JSON patch.

## Development

```
mix deps.get
mix test
```

The Rust crate lives under `native/feoxdb_nif`; `mix compile` builds it
automatically via Rustler.
