defmodule MrEric.RAG.Cache do
  @moduledoc """
  Bounded in-memory cache of built RAG indexes (Spec E).

  A `GenServer` owns an ETS table, so the cache dies with the process and
  nothing outlives a restart. Reads run in the calling process as a direct
  `:ets.lookup/2`; only `put/3` is serialized, because only `put/3` applies
  the bounds.

  **Building happens in the caller, never here.** `MrEric.RAG.Index.build/1`
  reads an unbounded number of files, and Spec D established what happens when
  work like that runs inside a process everything else waits on. The cost is
  that two simultaneous misses on the same key both build; they produce the
  same index, and that is cheaper than serializing every build.

  ## Limits

  `@defaults` is the single source of truth. Configuration is override-only:

      config :mr_eric, :rag_cache, max_cached_total_bytes: 96_000_000

  `fetch!/1` has no catch-all clause and no default parameter: an unknown key
  raises at the call site rather than returning a plausible number.

  The bound is **bytes, not chunks**. A chunk's `content` is capped by
  `chunk_size`, but the `:terms` map is not capped by anything the cache
  controls, and it is the larger half. Measured on the MrEric repository
  itself (2026-08-28): 148 files, 819 chunks, 1.16 MiB of content, 0.17 MiB
  of chunk structures, 3.99 MiB of term maps -- 5.32 MiB total, 6,811 B per
  chunk. A `max_cached_chunks: 20_000` bound, which is what this module was
  first drafted with, would have permitted ~136 MiB per index. Spec D reached
  the same conclusion about the trace and `CLAUDE.md` records it: bounded by
  size, not only by entry count.
  """

  use GenServer

  @table __MODULE__

  @defaults %{
    # Largest single index kept. ~4.5x the MrEric repository's own index, so a
    # project several times larger still caches. Beyond this the index is
    # returned to the caller and simply not stored.
    max_cached_index_bytes: 24_000_000,
    # The real ceiling across every cached index: two full-size ones, or ~9 of
    # this repository. For scale, the run side budgets ~8 MiB
    # (max_trace_payload_chars x max_trace_entries x max_concurrent_runs).
    max_cached_total_bytes: 48_000_000,
    # Key-count guard, so many tiny workspaces cannot grow the table without
    # limit. Not a memory bound -- that is what the two byte limits are.
    max_cached_indexes: 4
  }

  # Measured map-entry overhead: 75,719 term entries occupied 4,183,256 B of
  # heap, of which 481,435 B were key bytes, leaving 48.8 B per entry. The flat
  # per-chunk figure covers the chunk map itself. The model predicts 5.28 MiB
  # against a measured 5.32 MiB -- within 1.6 %.
  @term_entry_overhead_bytes 48
  @chunk_overhead_bytes 200

  @doc "The built-in defaults, keyed by limit name."
  def defaults, do: @defaults

  @doc """
  Returns the configured value for `key`, or its built-in default.

  Raises `FunctionClauseError` for an unsupported key.
  """
  def fetch!(key) when is_map_key(@defaults, key) do
    :mr_eric
    |> Application.get_env(:rag_cache, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The cache key for a set of index options.

  Every option that can change the *content* of an index is here.
  `allow_secret_paths` most of all: it decides whether `config/`,
  `priv/cert/`, `priv/secrets/` and `Policy.secret_path?/1` matches are walked
  at all, so a key that omitted it would let an index built for a caller that
  asked for secrets be served to one that asked for the safe index. That is
  the only way a cache can reopen the boundary Spec A closed. Key construction
  lives here and nowhere else.
  """
  def key(opts) do
    {
      MrEric.Tools.Policy.workspace_root(opts),
      Keyword.get(opts, :allow_secret_paths, false),
      Keyword.get(opts, :include_extensions),
      Keyword.get(opts, :extra_ignored_dirs, []),
      normalize_regexes(Keyword.get(opts, :extra_ignored_files, [])),
      Keyword.get(opts, :max_file_bytes),
      Keyword.get(opts, :chunk_size, Keyword.get(opts, :rag_chunk_size)),
      Keyword.get(opts, :chunk_overlap, Keyword.get(opts, :rag_chunk_overlap)),
      Keyword.get(opts, :paths) || Keyword.get(opts, :rag_paths)
    }
  end

  @doc "Looks the key up, in the calling process. `:stale` means the fingerprint moved."
  def fetch(key, fingerprint) do
    case :ets.lookup(@table, key) do
      [{^key, ^fingerprint, index}] ->
        GenServer.cast(__MODULE__, {:touch, key})
        {:ok, index}

      [{^key, _other_fingerprint, _index}] ->
        :stale

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores `index`, applying the bounds. Oversized indexes are silently not stored."
  def put(key, fingerprint, index) do
    GenServer.call(__MODULE__, {:put, key, fingerprint, index})
  end

  @doc "Empties the cache. For tests."
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  The modelled resident size of `index`, in bytes.

  Content bytes, plus each term key's bytes and the measured per-entry map
  overhead, plus a flat per-chunk allowance for the chunk map itself.
  """
  def index_bytes(%{chunks: chunks}) when is_list(chunks) do
    Enum.reduce(chunks, 0, fn chunk, acc ->
      acc + chunk_bytes(chunk)
    end)
  end

  def index_bytes(_index), do: 0

  defp chunk_bytes(chunk) do
    content = Map.get(chunk, :content, "")
    content_bytes = if is_binary(content), do: byte_size(content), else: 0

    content_bytes + term_bytes(Map.get(chunk, :terms)) +
      term_bytes(Map.get(chunk, :path_terms)) + @chunk_overhead_bytes
  end

  defp term_bytes(terms) when is_map(terms) do
    Enum.reduce(terms, 0, fn {term, _count}, acc ->
      acc + byte_size(term) + @term_entry_overhead_bytes
    end)
  end

  defp term_bytes(_terms), do: 0

  defp normalize_regexes(patterns) when is_list(patterns) do
    Enum.map(patterns, fn
      %Regex{} = regex -> {Regex.source(regex), Regex.opts(regex)}
      other -> other
    end)
  end

  defp normalize_regexes(other), do: other

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{table: table, reads: %{}, counter: 0}}
  end

  @impl true
  def handle_call({:put, key, fingerprint, index}, _from, state) do
    bytes = index_bytes(index)

    if bytes > fetch!(:max_cached_index_bytes) do
      {:reply, :ok, state}
    else
      :ets.insert(@table, {key, fingerprint, index})
      state = touch(state, key)
      {:reply, :ok, evict(state)}
    end
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | reads: %{}, counter: 0}}
  end

  @impl true
  def handle_cast({:touch, key}, state) do
    {:noreply, touch(state, key)}
  end

  defp touch(state, key) do
    counter = state.counter + 1
    %{state | counter: counter, reads: Map.put(state.reads, key, counter)}
  end

  # Least-recently-read first, until both the count and the total byte budget
  # fit. Reading the whole table to total it is fine: `max_cached_indexes` is
  # a single-digit number.
  defp evict(state) do
    entries =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {key, _fingerprint, index} ->
        {Map.get(state.reads, key, 0), key, index_bytes(index)}
      end)
      |> Enum.sort()

    max_indexes = fetch!(:max_cached_indexes)
    max_total = fetch!(:max_cached_total_bytes)

    {kept_reads, _count, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({state.reads, 0, 0}, fn {_read, key, bytes}, {reads, count, total} ->
        if count + 1 > max_indexes or total + bytes > max_total do
          :ets.delete(@table, key)
          {Map.delete(reads, key), count, total}
        else
          {reads, count + 1, total + bytes}
        end
      end)

    %{state | reads: kept_reads}
  end
end
