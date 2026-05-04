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
end
