defmodule FeoxDB.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :feox_db,
    crate: "feoxdb_nif",
    base_url: "https://github.com/ziinc/feoxdb-ex/releases/download/v#{version}",
    force_build: System.get_env("FEOXDB_BUILD") in ["1", "true"] || true,
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

  # Milestones 4-5 (PRD section 8) will publish precompiled artifacts and flip
  # `force_build` back to only trigger via `FEOXDB_BUILD=true`. Until then this
  # module always builds from source with the local Rust toolchain.

  def open(_path, _file_size, _max_memory, _hash_bits, _enable_ttl),
    do: :erlang.nif_error(:nif_not_loaded)

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
