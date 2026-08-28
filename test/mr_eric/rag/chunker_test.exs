defmodule MrEric.RAG.ChunkerTest do
  use ExUnit.Case, async: true

  alias MrEric.RAG.Chunker

  test "chunks text with stable ids, paths, and line ranges" do
    text = Enum.map_join(1..12, "\n", &"line #{&1} mentions Phoenix approval policy")

    chunks =
      Chunker.chunk_text("lib/example.ex", text,
        chunk_size: 90,
        chunk_overlap: 20
      )

    assert length(chunks) > 1

    assert [
             %{
               id: id,
               path: "lib/example.ex",
               start_line: 1,
               end_line: end_line,
               content: content
             }
             | _
           ] = chunks

    assert is_binary(id)
    assert end_line >= 1
    assert content =~ "line 1"
    assert Enum.all?(chunks, &(&1.path == "lib/example.ex"))
  end

  test "chunks carry precomputed terms for content and path" do
    [chunk | _] =
      Chunker.chunk_text(
        "lib/mr_eric/tools/policy.ex",
        "approval gate keeps shell commands safe\n"
      )

    assert chunk.terms["approval"] == 1
    assert chunk.terms["shell"] == 1
    assert chunk.path_terms["policy"] == 1
    assert chunk.path_terms["mr_eric"] == 1
  end

  test "terms drop tokens shorter than two characters, like the retriever's tokenizer" do
    [chunk | _] = Chunker.chunk_text("a.ex", "a bb ccc\n")

    refute Map.has_key?(chunk.terms, "a")
    assert chunk.terms["bb"] == 1
    assert chunk.terms["ccc"] == 1
  end

  test "term_frequencies/1 counts each distinct token once, matching the retriever" do
    # The retriever's tokenizer uniqs before frequencies are taken, so the
    # scorer has always counted distinct tokens, not occurrences. Storing real
    # counts here would silently change every ranking.
    assert Chunker.term_frequencies("run run run worker") == %{"run" => 1, "worker" => 1}
  end

  test "term_frequencies/1 returns an empty map for a non-binary" do
    assert Chunker.term_frequencies(nil) == %{}
  end
end
