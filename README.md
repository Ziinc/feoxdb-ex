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


## License

MIT

