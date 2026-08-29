defmodule FeoxDB do
  @moduledoc """
  Elixir bindings for [FeOxDB](https://feoxdb.com), an embedded key-value
  store written in Rust.

  A `FeoxDB` store can run purely in memory, or persist to disk in the
  background. See the project PRD (`docs/PRD.md`) for the full design
  rationale, including which operations run as plain, dirty, or (eventually)
  chunked NIFs.

  ## Example

      {:ok, store} = FeoxDB.open()
      :ok = FeoxDB.insert(store, "key", "value")
      {:ok, "value"} = FeoxDB.get(store, "key")
  """

  alias FeoxDB.Native

  @type store :: reference()
  @type key :: binary()
  @type value :: binary()

  # The upstream `feoxdb` Rust crate (pinned to `~> 0.6` in
  # `native/feoxdb_nif/Cargo.toml`, currently resolving to 0.6.0) enforces its
  # own key/value size limits and returns `InvalidKeySize` / `InvalidValueSize`
  # when they are exceeded (see `native/feoxdb_nif/src/error.rs`), but this
  # is not part of its public, documented API surface. Rather than rely
  # entirely on an external, unaudited crate to reject oversized input at the
  # FFI boundary, this module mirrors those limits and enforces them itself
  # before ever calling into native code.
  #
  # These values match `feoxdb::constants::MAX_KEY_SIZE` /
  # `MAX_VALUE_SIZE` in feoxdb 0.6.0's source
  # (https://docs.rs/crate/feoxdb/0.6.0/source/src/constants.rs). Since
  # they're undocumented internals of a dependency, not a stable public
  # contract, reviewers should double-check them against whatever `feoxdb`
  # version is actually pinned and update these if the crate changes them.
  @max_key_size 100 * 1024
  @max_value_size 4 * 1024 * 1024

  @type error_reason ::
          :not_found
          | :out_of_memory
          | :out_of_space
          | :older_timestamp
          | :invalid_json
          | :invalid_key_size
          | :invalid_value_size
          | :key_too_large
          | :value_too_large
          | :database_full
          | :invalid_range
          | :ttl_not_enabled
          | :invalid_argument
          | :corrupted_data
          | :duplicate_key
          | :size_mismatch
          | :stale_extent
          | :io_error
          | :timeout
          | :not_implemented
          | :unsupported
          | :unknown_error

  ## Lifecycle

  @doc """
  Opens a `FeoxDB` store.

  With no options, the store is memory-only. Pass `path:` to persist to
  disk.

  ## Options

    * `:path` - device path for persistent storage. When omitted, the store
      is memory-only.
    * `:file_size` - initial file size in bytes for a new persistent store.
    * `:max_memory` - maximum memory usage in bytes. Defaults to the
      upstream FeOxDB default (1GB) when a persistent path is given, or
      unlimited for memory-only stores unless set explicitly.
    * `:hash_bits` - number of hash table bits (bucket count is `2^bits`).
    * `:enable_ttl` - enables TTL support (`ttl/2`, `update_ttl/3`,
      `persist/2`, and TTL-bearing inserts). Defaults to `false`.
  """
  @spec open(keyword()) :: {:ok, store()} | {:error, error_reason()}
  def open(opts \\ []) do
    path = validate_type!(opts, :path, [nil, :binary])
    file_size = validate_type!(opts, :file_size, [nil, :pos_integer])
    max_memory = validate_type!(opts, :max_memory, [nil, :pos_integer])
    hash_bits = validate_type!(opts, :hash_bits, [nil, :pos_integer])
    enable_ttl = validate_type!(opts, :enable_ttl, [:boolean], false)

    case Native.open(path, file_size, max_memory, hash_bits, enable_ttl) do
      {:error, reason} -> {:error, reason}
      store -> {:ok, store}
    end
  end

  @doc "Same as `open/1` but raises `FeoxDB.Error` on failure."
  @spec open!(keyword()) :: store()
  def open!(opts \\ []) do
    unwrap!(open(opts))
  end

  @doc """
  Flushes all buffered writes to disk.

  Runs as a dirty I/O NIF (PRD section 5) because it waits for `fsync`.
  No-op for memory-only stores.
  """
  @spec flush(store()) :: :ok | {:error, error_reason()}
  def flush(store) do
    case Native.flush(store) do
      {:error, reason} -> {:error, reason}
      :ok -> :ok
    end
  end

  ## Basic operations

  @doc """
  Retrieves the value for `key`.

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec get(store(), key()) :: {:ok, value()} | {:error, error_reason()}
  def get(store, key) when is_binary(key) do
    with :ok <- validate_key_size(key) do
      case Native.get(store, key) do
        {:error, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    end
  end

  @doc "Same as `get/2` but raises `FeoxDB.Error` on failure."
  @spec get!(store(), key()) :: value()
  def get!(store, key) do
    unwrap!(get(store, key))
  end

  @doc """
  Inserts or updates `key` with `value`.

  Pass `ttl: seconds` to set an expiry (requires `enable_ttl: true` at
  `open/1` time).

  Returns `{:error, :key_too_large}` if `key` is larger than
  #{@max_key_size} bytes, or `{:error, :value_too_large}` if `value` is
  larger than #{@max_value_size} bytes, without calling into native code.
  """
  @spec insert(store(), key(), value(), keyword()) :: :ok | {:error, error_reason()}
  def insert(store, key, value, opts \\ []) when is_binary(key) and is_binary(value) do
    ttl = Keyword.get(opts, :ttl)

    with :ok <- validate_key_size(key),
         :ok <- validate_value_size(value) do
      case Native.insert(store, key, value, ttl) do
        {:error, reason} -> {:error, reason}
        _new_or_updated? -> :ok
      end
    end
  end

  @doc "Same as `insert/4` but raises `FeoxDB.Error` on failure."
  @spec insert!(store(), key(), value(), keyword()) :: :ok
  def insert!(store, key, value, opts \\ []) do
    unwrap!(insert(store, key, value, opts))
  end

  @doc """
  Deletes `key`.

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec delete(store(), key()) :: :ok | {:error, error_reason()}
  def delete(store, key) when is_binary(key) do
    with :ok <- validate_key_size(key) do
      case Native.delete(store, key) do
        {:error, reason} -> {:error, reason}
        :ok -> :ok
      end
    end
  end

  @doc """
  Returns whether `key` exists in the store.

  A `key` larger than #{@max_key_size} bytes can never have been inserted
  (see `insert/4`), so this returns `false` for it directly, without calling
  into native code.
  """
  @spec member?(store(), key()) :: boolean()
  def member?(store, key) when is_binary(key) do
    case validate_key_size(key) do
      :ok -> Native.member(store, key)
      {:error, :key_too_large} -> false
    end
  end

  @doc "Returns the number of records in the store."
  @spec size(store()) :: non_neg_integer()
  def size(store) do
    Native.size(store)
  end

  @doc "Returns the store's memory usage, in bytes."
  @spec memory_usage(store()) :: non_neg_integer()
  def memory_usage(store) do
    Native.memory_usage(store)
  end

  ## Ranges

  @doc """
  Returns up to `limit` key-value pairs with keys in `[start_key, end_key]`
  (both bounds inclusive), ordered by key.

  `limit` is required: an unbounded range query could run for an unknown
  time on the scheduler and build an unbounded term (PRD section 7).

  Runs as a dirty I/O NIF, since the cost of a scan depends on `limit`.

  Returns `{:error, :key_too_large}` if `start_key` or `end_key` is larger
  than #{@max_key_size} bytes, without calling into native code.
  """
  @spec range(store(), key(), key(), pos_integer()) ::
          {:ok, [{key(), value()}]} | {:error, error_reason()}
  def range(store, start_key, end_key, limit)
      when is_binary(start_key) and is_binary(end_key) and is_integer(limit) and limit > 0 do
    with :ok <- validate_key_size(start_key),
         :ok <- validate_key_size(end_key) do
      case Native.range(store, start_key, end_key, limit) do
        {:error, reason} -> {:error, reason}
        pairs -> {:ok, pairs}
      end
    end
  end

  ## TTL

  @doc """
  Returns the remaining TTL in seconds for `key`, or `nil` if it has none.

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec ttl(store(), key()) :: {:ok, non_neg_integer() | nil} | {:error, error_reason()}
  def ttl(store, key) when is_binary(key) do
    with :ok <- validate_key_size(key) do
      case Native.ttl(store, key) do
        {:error, reason} -> {:error, reason}
        seconds -> {:ok, seconds}
      end
    end
  end

  @doc """
  Sets `key`'s TTL to `seconds` from now.

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec update_ttl(store(), key(), pos_integer()) :: :ok | {:error, error_reason()}
  def update_ttl(store, key, seconds)
      when is_binary(key) and is_integer(seconds) and seconds > 0 do
    with :ok <- validate_key_size(key) do
      case Native.update_ttl(store, key, seconds) do
        {:error, reason} -> {:error, reason}
        :ok -> :ok
      end
    end
  end

  @doc """
  Removes `key`'s TTL, making it permanent.

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec persist(store(), key()) :: :ok | {:error, error_reason()}
  def persist(store, key) when is_binary(key) do
    with :ok <- validate_key_size(key) do
      case Native.persist(store, key) do
        {:error, reason} -> {:error, reason}
        :ok -> :ok
      end
    end
  end

  ## Atomics

  @doc """
  Atomically adds `delta` to the integer stored at `key` and returns the new
  value.

  The value is stored internally as an 8-byte little-endian `i64`; this
  function takes and returns a plain Elixir integer; the little-endian
  conversion happens on the Rust side; there is no `<<n::signed-little-64>>`
  to get wrong (PRD section 7).

  Returns `{:error, :key_too_large}` if `key` is larger than #{@max_key_size}
  bytes, without calling into native code.
  """
  @spec increment(store(), key(), integer()) :: {:ok, integer()} | {:error, error_reason()}
  def increment(store, key, delta \\ 1) when is_binary(key) and is_integer(delta) do
    with :ok <- validate_key_size(key) do
      case Native.increment(store, key, delta) do
        {:error, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    end
  end

  @doc """
  Atomically replaces `key`'s value with `new_value` if it currently equals
  `expected`.

  Returns `{:error, :key_too_large}` if `key` is larger than
  #{@max_key_size} bytes, or `{:error, :value_too_large}` if `expected` or
  `new_value` is larger than #{@max_value_size} bytes, without calling into
  native code.
  """
  @spec compare_and_swap(store(), key(), value(), value()) ::
          {:ok, boolean()} | {:error, error_reason()}
  def compare_and_swap(store, key, expected, new_value)
      when is_binary(key) and is_binary(expected) and is_binary(new_value) do
    with :ok <- validate_key_size(key),
         :ok <- validate_value_size(expected),
         :ok <- validate_value_size(new_value) do
      case Native.compare_and_swap(store, key, expected, new_value) do
        {:error, reason} -> {:error, reason}
        swapped? -> {:ok, swapped?}
      end
    end
  end

  ## JSON

  @doc """
  Applies an RFC 6902 JSON patch to the JSON document stored at `key`.

  Returns `{:error, :key_too_large}` if `key` is larger than
  #{@max_key_size} bytes, or `{:error, :value_too_large}` if `patch` is
  larger than #{@max_value_size} bytes, without calling into native code.
  """
  @spec json_patch(store(), key(), binary()) :: :ok | {:error, error_reason()}
  def json_patch(store, key, patch) when is_binary(key) and is_binary(patch) do
    with :ok <- validate_key_size(key),
         :ok <- validate_value_size(patch) do
      case Native.json_patch(store, key, patch) do
        {:error, reason} -> {:error, reason}
        :ok -> :ok
      end
    end
  end

  ## Stats

  @doc "Returns a snapshot of the store's internal statistics as a map."
  @spec stats(store()) :: map()
  def stats(store) do
    Native.stats(store)
  end

  defp unwrap!(:ok), do: :ok
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: raise(FeoxDB.Error, reason: reason)

  # `FeoxStore` can panic on out-of-range values, which would crash the whole
  # BEAM node (PRD section 11, open question 5). Validate here instead of
  # trusting the Rust side.
  defp validate_type!(opts, key, allowed_types, default \\ nil) do
    value = Keyword.get(opts, key, default)

    if Enum.any?(allowed_types, &matches_type?(value, &1)) do
      value
    else
      raise ArgumentError,
            "invalid value for #{inspect(key)}: #{inspect(value)} " <>
              "(expected one of #{inspect(allowed_types)})"
    end
  end

  defp matches_type?(nil, nil), do: true
  defp matches_type?(value, :binary), do: is_binary(value)
  defp matches_type?(value, :pos_integer), do: is_integer(value) and value > 0
  defp matches_type?(value, :boolean), do: is_boolean(value)
  defp matches_type?(_value, _type), do: false

  @spec validate_key_size(key()) :: :ok | {:error, :key_too_large}
  defp validate_key_size(key) when byte_size(key) <= @max_key_size, do: :ok
  defp validate_key_size(_key), do: {:error, :key_too_large}

  @spec validate_value_size(value()) :: :ok | {:error, :value_too_large}
  defp validate_value_size(value) when byte_size(value) <= @max_value_size, do: :ok
  defp validate_value_size(_value), do: {:error, :value_too_large}
end
