defmodule MrEric.RAG do
  @moduledoc """
  Public RAG facade for building planner context from project files.
  """

  alias MrEric.RAG.Cache
  alias MrEric.RAG.Index
  alias MrEric.RAG.Retriever

  @default_max_context_chars 6_000

  def context_for(task, opts \\ [])

  def context_for(task, opts) when is_binary(task) do
    with {:ok, index} <- index_for(opts) do
      context =
        index
        |> Retriever.search(task, opts)
        |> format_context(opts)

      {:ok, context}
    end
  end

  def context_for(_task, _opts), do: {:ok, ""}

  # `opts[:rag_index]` stays the caller's escape hatch and never touches the
  # cache. Otherwise: identify the tree with an lstat-only walk, use the cached
  # index if it matches, and build in this process on a miss or a mismatch --
  # never inside the cache GenServer.
  defp index_for(opts) do
    case Keyword.get(opts, :rag_index) do
      %{chunks: chunks} = index when is_list(chunks) ->
        {:ok, index}

      _none ->
        case Index.fingerprint(opts) do
          {:ok, fingerprint, paths} -> cached_index(opts, fingerprint, paths)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp cached_index(opts, fingerprint, paths) do
    key = Cache.key(opts)

    case Cache.fetch(key, fingerprint) do
      {:ok, index} ->
        {:ok, index}

      _stale_or_miss ->
        # Hand `build/1` the paths the fingerprint walk already found, so the
        # tree is walked once per `context_for/2` rather than twice.
        with {:ok, index} <- Index.build(Keyword.put(opts, :paths, paths)) do
          Cache.put(key, fingerprint, index)
          {:ok, index}
        end
    end
  end

  defp format_context([], _opts), do: ""

  defp format_context(chunks, opts) do
    max_context_chars = Keyword.get(opts, :rag_max_context_chars, @default_max_context_chars)

    body =
      chunks
      |> Enum.map(&format_chunk/1)
      |> Enum.join("\n\n")
      |> String.slice(0, max_context_chars)

    "Project context:\n\n" <> body
  end

  defp format_chunk(chunk) do
    path = Map.fetch!(chunk, :path)
    start_line = Map.fetch!(chunk, :start_line)
    end_line = Map.fetch!(chunk, :end_line)
    content = chunk |> Map.get(:content, "") |> String.trim()

    "[#{path}:#{start_line}-#{end_line}]\n#{content}"
  end
end
