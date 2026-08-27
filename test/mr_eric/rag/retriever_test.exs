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

  test "search does not downcase content for chunks with no lexical match", %{chunks: chunks} do
    # The exact bonus must not be computed for a chunk that scored zero
    # lexically. Proven structurally: a chunk whose content cannot be
    # downcased would crash if the bonus were still evaluated for it.
    poisoned = %{
      id: "poison",
      path: "poison.md",
      start_line: 1,
      end_line: 1,
      content: :not_a_binary,
      terms: %{},
      path_terms: %{}
    }

    assert [_ | _] = Retriever.search(index(chunks ++ [poisoned]), "approval gate")
  end
end
