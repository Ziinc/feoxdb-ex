defmodule FeoxDB.Term do
  @moduledoc """
  Stores arbitrary Erlang terms in a `FeoxDB` store, using the External Term
  Format (ETF) for both keys and values.

  Values whose encoding is larger than FeoxDB's per-value limit are split
  into chunks transparently: `put/4` writes the chunks under internal keys
  followed by a small manifest under the key itself, and `get/2` reassembles
  them. Callers never see the chunks.

      {:ok, store} = FeoxDB.open()
      :ok = FeoxDB.Term.put(store, {:user, 1}, %{name: "Ada"})
      {:ok, %{name: "Ada"}} = FeoxDB.Term.get(store, {:user, 1})

  A store used through this module should only be accessed through this
  module: chunks live under keys that start with a `0` byte and every
  encoded key starts with the ETF version byte (`131`), so binary keys
  written with `FeoxDB.insert/4` can collide with either.

  Values are decoded with `:erlang.binary_to_term/2`'s `:safe` option, so a
  value referencing an atom that does not exist in the reading VM returns
  `{:error, :corrupted_data}` instead of creating it.

  A chunked overwrite writes the new chunks before the manifest that points
  at them and only then deletes the old chunks, so a concurrent `get/2`
  sees either the old or the new value.
  """

  @inline 0
  @chunked 1
  @chunk_prefix 0
  @gen_size 16
  # Chunk keys add the prefix byte, the generation and a 32-bit index.
  @chunk_key_overhead 1 + @gen_size + 4
  @page_size 1_000

  @doc """
  Stores `value` under `key`, both arbitrary terms.

  ## Options

    * `:ttl` - expiry in seconds, as in `FeoxDB.insert/4`.
    * `:chunk_size` - maximum bytes stored per record before the value is
      split into chunks. Defaults to (and may not exceed) the FeoxDB value
      size limit.
  """
  @spec put(FeoxDB.store(), term(), term(), keyword()) :: :ok | {:error, FeoxDB.error_reason()}
  def put(store, key, value, opts \\ []) do
    ekey = encode_key(key)
    etf = :erlang.term_to_binary(value)
    chunk_size = chunk_size(opts)
    insert_opts = Keyword.take(opts, [:ttl])
    old = FeoxDB.get(store, ekey)

    result =
      if byte_size(etf) < chunk_size do
        FeoxDB.insert(store, ekey, <<@inline, etf::binary>>, insert_opts)
      else
        put_chunked(store, ekey, etf, chunk_size, insert_opts)
      end

    with :ok <- result do
      delete_chunks(store, ekey, old)
    end
  end

  @doc "Returns the term stored under `key`."
  @spec get(FeoxDB.store(), term()) :: {:ok, term()} | {:error, FeoxDB.error_reason()}
  def get(store, key) do
    ekey = encode_key(key)

    with {:ok, raw} <- FeoxDB.get(store, ekey) do
      case decode_value(store, ekey, raw) do
        # A concurrent overwrite deleted the chunks this manifest pointed at;
        # the new manifest is already in place.
        {:error, :stale_extent} -> get_once(store, ekey)
        other -> other
      end
    end
  end

  @doc "Deletes `key` and any chunks of its value."
  @spec delete(FeoxDB.store(), term()) :: :ok | {:error, FeoxDB.error_reason()}
  def delete(store, key) do
    ekey = encode_key(key)

    case FeoxDB.get(store, ekey) do
      {:ok, _raw} = old ->
        with :ok <- FeoxDB.delete(store, ekey), do: delete_chunks(store, ekey, old)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns whether `key` exists in the store."
  @spec member?(FeoxDB.store(), term()) :: boolean() | {:error, FeoxDB.error_reason()}
  def member?(store, key) do
    FeoxDB.member?(store, encode_key(key))
  end

  @doc """
  Returns a lazy stream of every `{key, value}` pair in the store, in ETF
  key order. Chunked values are reassembled; entries deleted while the
  stream runs are skipped.
  """
  @spec stream(FeoxDB.store()) :: Enumerable.t({term(), term()})
  def stream(store) do
    Stream.resource(
      fn -> <<131>> end,
      &next_page(store, &1),
      fn _ -> :ok end
    )
  end

  defp next_page(_store, :done), do: {:halt, :done}

  defp next_page(store, start) do
    # Every ETF-encoded key starts with 131, so `<<132>>` bounds them all.
    case FeoxDB.range(store, start, <<132>>, @page_size) do
      {:ok, []} ->
        {:halt, :done}

      {:ok, pairs} ->
        {last_key, _} = List.last(pairs)
        next = if length(pairs) < @page_size, do: :done, else: last_key <> <<0>>
        {Enum.flat_map(pairs, &decode_pair(store, &1)), next}

      {:error, reason} ->
        raise FeoxDB.Error, reason: reason
    end
  end

  defp decode_pair(store, {ekey, raw}) do
    with {:ok, key} <- safe_binary_to_term(ekey),
         {:ok, value} <- decode_value(store, ekey, raw) do
      [{key, value}]
    else
      {:error, _reason} -> []
    end
  end

  defp get_once(store, ekey) do
    with {:ok, raw} <- FeoxDB.get(store, ekey) do
      case decode_value(store, ekey, raw) do
        {:error, :stale_extent} -> {:error, :not_found}
        other -> other
      end
    end
  end

  defp put_chunked(store, ekey, etf, chunk_size, insert_opts) do
    if byte_size(ekey) + @chunk_key_overhead > FeoxDB.max_key_size() do
      {:error, :key_too_large}
    else
      gen = new_gen()
      chunks = split(etf, chunk_size)

      manifest = <<@chunked, gen::binary, length(chunks)::32, byte_size(etf)::64>>

      with :ok <- write_chunks(store, ekey, gen, chunks, insert_opts),
           :ok <- FeoxDB.insert(store, ekey, manifest, insert_opts) do
        :ok
      else
        error ->
          delete_gen(store, ekey, gen, length(chunks))
          error
      end
    end
  end

  defp write_chunks(store, ekey, gen, chunks, insert_opts) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, idx}, :ok ->
      case FeoxDB.insert(store, chunk_key(ekey, gen, idx), chunk, insert_opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_value(_store, _ekey, <<@inline, etf::binary>>), do: safe_binary_to_term(etf)

  defp decode_value(
         store,
         ekey,
         <<@chunked, gen::binary-size(@gen_size), count::32, total::64>>
       ) do
    0..(count - 1)
    |> Enum.reduce_while([], fn idx, acc ->
      case FeoxDB.get(store, chunk_key(ekey, gen, idx)) do
        {:ok, chunk} -> {:cont, [acc, chunk]}
        {:error, :not_found} -> {:halt, {:error, :stale_extent}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} ->
        {:error, reason}

      iodata ->
        etf = IO.iodata_to_binary(iodata)

        if byte_size(etf) == total,
          do: safe_binary_to_term(etf),
          else: {:error, :size_mismatch}
    end
  end

  defp decode_value(_store, _ekey, _raw), do: {:error, :corrupted_data}

  defp delete_chunks(
         store,
         ekey,
         {:ok, <<@chunked, gen::binary-size(@gen_size), count::32, _total::64>>}
       ) do
    delete_gen(store, ekey, gen, count)
  end

  defp delete_chunks(_store, _ekey, _old), do: :ok

  defp delete_gen(store, ekey, gen, count) do
    Enum.each(0..(count - 1)//1, &FeoxDB.delete(store, chunk_key(ekey, gen, &1)))
  end

  defp split(bin, size) when byte_size(bin) <= size, do: [bin]

  defp split(bin, size) do
    <<chunk::binary-size(^size), rest::binary>> = bin
    [chunk | split(rest, size)]
  end

  defp chunk_key(ekey, gen, idx), do: <<@chunk_prefix, ekey::binary, gen::binary, idx::32>>

  # Unique within this VM via `unique_integer`, and across restarts of a
  # persistent store via the wall-clock prefix.
  defp new_gen do
    <<System.os_time(:nanosecond)::64, :erlang.unique_integer([:positive])::64>>
  end

  defp encode_key(key), do: :erlang.term_to_binary(key, [:deterministic])

  defp chunk_size(opts) do
    max = FeoxDB.max_value_size()

    case Keyword.get(opts, :chunk_size, max) do
      size when is_integer(size) and size > 1 and size <= max ->
        size

      other ->
        raise ArgumentError,
              "invalid value for :chunk_size: #{inspect(other)} (expected 2..#{max})"
    end
  end

  # Only decodes bytes this module wrote with `term_to_binary/1`, and `:safe`
  # refuses to create atoms, so Sobelow's generic warning does not apply.
  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> {:error, :corrupted_data}
  end
end
