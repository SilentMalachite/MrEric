defmodule MrEric.RAG.RetrieverTest do
  use ExUnit.Case, async: true

  alias MrEric.RAG.Chunker
  alias MrEric.RAG.Retriever

  defp index(chunks), do: %{chunks: chunks}

  defp chunk(path, content) do
    [c | _] = Chunker.chunk_text(path, content)
    c
  end

  defp legacy(chunk), do: Map.drop(chunk, [:terms, :path_terms])

  defp key(results), do: Enum.map(results, &{&1.path, &1.start_line, &1.score})

  # The scorer exactly as it shipped before Spec E, transcribed from the
  # merge-base revision of `retriever.ex`. Acceptance 8 asks for identical
  # `{path, start_line, score}` triples in identical order, and only a
  # comparison against the *old* code can show that -- running the new
  # `search/3` twice over two chunk shapes cannot.
  defp legacy_search(chunks, query, top_k \\ 5) do
    tokens = legacy_tokenize(query)

    if tokens == [] do
      []
    else
      chunks
      |> Enum.map(&Map.put(&1, :score, legacy_score(&1, tokens, query)))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.sort_by(&{-&1.score, &1.path, &1.start_line})
      |> Enum.take(top_k)
    end
  end

  defp legacy_score(chunk, query_tokens, query) do
    content = Map.get(chunk, :content, "")
    path = Map.get(chunk, :path, "")
    content_terms = content |> legacy_tokenize() |> Enum.frequencies()
    path_terms = path |> legacy_tokenize() |> Enum.frequencies()

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

  defp legacy_tokenize(text) when is_binary(text) do
    ~r/[[:alnum:]_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end

  setup do
    chunks = [
      chunk("lib/mr_eric/tools/policy.ex", "approval gate keeps shell commands safe\n"),
      chunk("lib/mr_eric/runs/run_worker.ex", "the worker reaps a terminal run\n"),
      chunk("README.md", "MrEric orchestrates planner draft reviewer synthesizer\n"),
      chunk("docs/notes.md", "approval gate keeps shell commands safe again\n")
    ]

    {:ok, chunks: chunks}
  end

  test "precomputed and recomputed chunks score identically", %{chunks: chunks} do
    for query <- [
          "approval gate",
          "shell commands safe",
          "worker terminal run",
          "planner",
          "nothing matches here",
          "a",
          "MrEric"
        ] do
      precomputed = Retriever.search(index(chunks), query)
      recomputed = Retriever.search(index(Enum.map(chunks, &legacy/1)), query)

      assert key(precomputed) == key(recomputed), "mismatch for #{inspect(query)}"
    end
  end

  test "scores match the pre-Spec-E scorer exactly", %{chunks: chunks} do
    for query <- [
          "approval gate",
          "shell commands safe",
          "worker terminal run",
          "planner",
          "nothing matches here",
          "a",
          "MrEric",
          # Singular query, plural in the corpus: the bonus fires on a
          # substring, the lexical score does not.
          "command",
          # The query sits inside a single token.
          "eric",
          # The query spans a token boundary the tokenizer splits on.
          "gate keeps",
          "  approval gate  ",
          "APPROVAL GATE"
        ] do
      assert key(Retriever.search(index(chunks), query)) ==
               key(legacy_search(chunks, query)),
             "mismatch for #{inspect(query)}"
    end
  end

  test "a query that only matches as a substring still scores", %{chunks: chunks} do
    # "command" is not a token of "shell commands", so the lexical score is
    # zero, but the content contains it verbatim so the bonus is 5. Filtering
    # on the lexical score alone dropped these chunks entirely.
    assert key(Retriever.search(index(chunks), "command")) == [
             {"docs/notes.md", 1, 5},
             {"lib/mr_eric/tools/policy.ex", 1, 5}
           ]
  end

  test "the exact-phrase bonus still applies", %{chunks: chunks} do
    [top | _] = Retriever.search(index(chunks), "approval gate keeps shell commands safe")

    # 4 distinct query tokens present, +5 for containing the phrase verbatim.
    assert top.score >= 5
    assert top.path == "docs/notes.md" or top.path == "lib/mr_eric/tools/policy.ex"
  end

  test "a query of only one-character tokens returns nothing", %{chunks: chunks} do
    assert Retriever.search(index(chunks), "a b") == []
  end

  test "path tokens are still worth double", %{chunks: chunks} do
    [top | _] = Retriever.search(index(chunks), "run_worker")
    assert top.path == "lib/mr_eric/runs/run_worker.ex"
  end

  test "a chunk with non-binary content is scored, not crashed on", %{chunks: chunks} do
    # The bonus now runs over every chunk, so the `is_binary/1` guard in
    # `exact_bonus/2` is what keeps a malformed chunk from taking the query
    # down. It contributes nothing and drops out with the rest of the zeroes.
    poisoned = %{
      id: "poison",
      path: "poison.md",
      start_line: 1,
      end_line: 1,
      content: :not_a_binary,
      terms: %{},
      path_terms: %{}
    }

    results = Retriever.search(index(chunks ++ [poisoned]), "approval gate")

    assert [_ | _] = results
    refute Enum.any?(results, &(&1.path == "poison.md"))
  end
end
