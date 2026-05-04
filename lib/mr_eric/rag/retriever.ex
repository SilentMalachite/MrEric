defmodule MrEric.RAG.Retriever do
  @moduledoc """
  Scores indexed chunks using simple lexical overlap.
  """

  @default_top_k 5

  def search(index, query, opts \\ [])

  def search(%{chunks: chunks}, query, opts) when is_binary(query) and is_list(chunks) do
    tokens = tokenize(query)
    top_k = Keyword.get(opts, :top_k, Keyword.get(opts, :rag_top_k, @default_top_k))

    if tokens == [] do
      []
    else
      chunks
      |> Enum.map(&Map.put(&1, :score, score(&1, tokens, query)))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.sort_by(&{-&1.score, &1.path, &1.start_line})
      |> Enum.take(top_k)
    end
  end

  def search(_index, _query, _opts), do: []

  defp score(chunk, query_tokens, query) do
    content = Map.get(chunk, :content, "")
    path = Map.get(chunk, :path, "")
    content_terms = content |> tokenize() |> Enum.frequencies()
    path_terms = path |> tokenize() |> Enum.frequencies()

    lexical_score =
      Enum.reduce(query_tokens, 0, fn token, acc ->
        acc + Map.get(content_terms, token, 0) + Map.get(path_terms, token, 0) * 2
      end)

    exact_bonus =
      if String.contains?(String.downcase(content), String.downcase(String.trim(query))) do
        5
      else
        0
      end

    lexical_score + exact_bonus
  end

  defp tokenize(text) when is_binary(text) do
    ~r/[[:alnum:]_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end

  defp tokenize(_text), do: []
end
