defmodule FeoxDB.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  # `.github/workflows/release.yml` (PRD section 8.4) publishes precompiled
  # artifacts on every `v*` tag and, in the same run, opens a PR committing
  # a regenerated `checksum-Elixir.FeoxDB.Native.exs`. Until that file has
  # been committed once (i.e. before the first release), there is nothing
  # to download, so this always builds from source; once it exists,
  # RustlerPrecompiled's own checksum verification takes over and a
  # download is attempted first, same as any other RustlerPrecompiled
  # package. `FEOXDB_BUILD=true` always forces a source build regardless.
  checksum_path = Path.join(File.cwd!(), "checksum-Elixir.FeoxDB.Native.exs")

  use RustlerPrecompiled,
    otp_app: :feox_db,
    crate: "feoxdb_nif",
    base_url: "https://github.com/ziinc/feoxdb-ex/releases/download/v#{version}",
    force_build:
      System.get_env("FEOXDB_BUILD") in ["1", "true"] or not File.exists?(checksum_path),
    nif_versions: ["2.15"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-musl
    ),
    version: version

  def open(_path, _file_size, _max_memory, _hash_bits, _enable_ttl),
    do: :erlang.nif_error(:nif_not_loaded)

  def close(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def flush(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def get(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def insert(_resource, _key, _value, _ttl), do: :erlang.nif_error(:nif_not_loaded)
  def delete(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def member(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def size(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def memory_usage(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def range(_resource, _start_key, _end_key, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def ttl(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def update_ttl(_resource, _key, _seconds), do: :erlang.nif_error(:nif_not_loaded)
  def persist(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)
  def increment(_resource, _key, _delta), do: :erlang.nif_error(:nif_not_loaded)

  def compare_and_swap(_resource, _key, _expected, _new_value),
    do: :erlang.nif_error(:nif_not_loaded)

  def json_patch(_resource, _key, _patch), do: :erlang.nif_error(:nif_not_loaded)
  def stats(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
