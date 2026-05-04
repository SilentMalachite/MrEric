defmodule MrEric.RAG.Chunker do
  @moduledoc """
  Splits project text into small, line-addressable chunks for lexical RAG.
  """

  @default_chunk_size 1_600
  @default_chunk_overlap 160

  def chunk_text(path, text, opts \\ [])

  def chunk_text(path, text, opts) when is_binary(path) and is_binary(text) do
    if String.trim(text) == "" do
      []
    else
      chunk_size = positive_int(opts, :chunk_size, :rag_chunk_size, @default_chunk_size)
      chunk_overlap = overlap(opts, chunk_size)

      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: false)
      |> build_chunks(path, 1, chunk_size, chunk_overlap, [])
    end
  end

  def chunk_text(_path, _text, _opts), do: []

  defp build_chunks([], _path, _start_line, _chunk_size, _chunk_overlap, acc) do
    Enum.reverse(acc)
  end

  defp build_chunks(lines, path, start_line, chunk_size, chunk_overlap, acc) do
    {chunk_lines, rest} = take_chunk(lines, chunk_size)
    content = Enum.join(chunk_lines, "\n")

    cond do
      String.trim(content) == "" ->
        Enum.reverse(acc)

      rest == [] ->
        Enum.reverse([chunk(path, start_line, chunk_lines, content) | acc])

      true ->
        repeated_lines = repeated_overlap_lines(chunk_lines, chunk_overlap)
        end_line = start_line + length(chunk_lines) - 1
        next_start_line = end_line - length(repeated_lines) + 1

        build_chunks(
          repeated_lines ++ rest,
          path,
          next_start_line,
          chunk_size,
          chunk_overlap,
          [chunk(path, start_line, chunk_lines, content) | acc]
        )
    end
  end

  defp take_chunk(lines, chunk_size), do: take_chunk(lines, chunk_size, [], 0)

  defp take_chunk([], _chunk_size, acc, _size), do: {Enum.reverse(acc), []}

  defp take_chunk([line | rest], chunk_size, [], _size) do
    take_chunk(rest, chunk_size, [line], String.length(line))
  end

  defp take_chunk([line | _rest] = remaining, chunk_size, acc, size) do
    next_size = size + String.length(line) + 1

    if next_size > chunk_size do
      {Enum.reverse(acc), remaining}
    else
      [_line | rest] = remaining
      take_chunk(rest, chunk_size, [line | acc], next_size)
    end
  end

  defp repeated_overlap_lines(lines, overlap) when overlap <= 0 or length(lines) <= 1, do: []

  defp repeated_overlap_lines(lines, overlap) do
    max_repeated = length(lines) - 1

    {selected, _size} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn line, {selected, size} ->
        next_size = size + String.length(line) + 1

        if next_size <= overlap and length(selected) < max_repeated do
          {:cont, {[line | selected], next_size}}
        else
          {:halt, {selected, size}}
        end
      end)

    selected
  end

  defp chunk(path, start_line, lines, content) do
    end_line = start_line + length(lines) - 1

    %{
      id: chunk_id(path, start_line, end_line, content),
      path: path,
      start_line: start_line,
      end_line: end_line,
      content: content
    }
  end

  defp chunk_id(path, start_line, end_line, content) do
    :sha256
    |> :crypto.hash("#{path}:#{start_line}:#{end_line}:#{content}")
    |> Base.encode16(case: :lower)
  end

  defp overlap(opts, chunk_size) do
    opts
    |> positive_int(:chunk_overlap, :rag_chunk_overlap, @default_chunk_overlap)
    |> min(max(chunk_size - 1, 0))
  end

  defp positive_int(opts, key, fallback_key, default) do
    value = Keyword.get(opts, key, Keyword.get(opts, fallback_key, default))

    if is_integer(value) and value > 0 do
      value
    else
      default
    end
  end
end
