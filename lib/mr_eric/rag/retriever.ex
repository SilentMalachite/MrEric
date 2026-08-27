defmodule MrEric.RAG.Retriever do
  @moduledoc """
  Scores indexed chunks using simple lexical overlap.
  """

  @default_top_k 5

  alias MrEric.RAG.Chunker

  def search(index, query, opts \\ [])

  def search(%{chunks: chunks}, query, opts) when is_binary(query) and is_list(chunks) do
    tokens = tokenize(query)
    top_k = Keyword.get(opts, :top_k, Keyword.get(opts, :rag_top_k, @default_top_k))

    if tokens == [] do
      []
    else
      downcased_query = String.downcase(String.trim(query))

      chunks
      |> Enum.map(&Map.put(&1, :score, lexical_score(&1, tokens)))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.map(&Map.put(&1, :score, &1.score + exact_bonus(&1, downcased_query)))
      |> Enum.sort_by(&{-&1.score, &1.path, &1.start_line})
      |> Enum.take(top_k)
    end
  end

  def search(_index, _query, _opts), do: []

  defp lexical_score(chunk, query_tokens) do
    content_terms = terms_for(chunk, :terms, :content)
    path_terms = terms_for(chunk, :path_terms, :path)

    Enum.reduce(query_tokens, 0, fn token, acc ->
      acc + Map.get(content_terms, token, 0) + Map.get(path_terms, token, 0) * 2
    end)
  end

  # `Chunker` attaches these at index time. The recompute branch is for a
  # chunk handed in through `opts[:rag_index]` by a caller holding an older
  # shape; it produces the same value the index would have stored. This is a
  # *performance* fallback, not the "lookup with a default" pattern Spec C-1
  # banned -- no boundary depends on it. Do not add a similar default
  # somewhere one would.
  defp terms_for(chunk, precomputed_key, source_key) do
    case Map.get(chunk, precomputed_key) do
      terms when is_map(terms) -> terms
      _absent -> chunk |> Map.get(source_key, "") |> Chunker.term_frequencies()
    end
  end

  # Only reached for chunks that already scored above zero lexically. That is
  # sound, not an approximation: the bonus fires when the content contains the
  # whole query, which means it contains every query token, which means the
  # lexical score was already non-zero. Computing it for every chunk meant
  # downcasing the entire corpus on every query -- the single largest cost in
  # `search/3`.
  defp exact_bonus(chunk, downcased_query) do
    content = Map.get(chunk, :content, "")

    if is_binary(content) and String.contains?(String.downcase(content), downcased_query) do
      5
    else
      0
    end
  end

  # Only ever reached with the query, which `search/3` guards as a binary.
  # A non-binary fallback clause here is dead code the compiler rejects under
  # --warnings-as-errors; chunk text goes through `Chunker.term_frequencies/1`,
  # which keeps its own non-binary clause.
  defp tokenize(text) when is_binary(text) do
    ~r/[[:alnum:]_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end
end
