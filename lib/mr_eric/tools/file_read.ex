defmodule MrEric.Tools.FileRead do
  @moduledoc """
  Reads a text file inside the configured workspace.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @impl true
  def name, do: :file_read

  @impl true
  def description, do: "Read a file from the workspace."

  @impl true
  def schema do
    %{
      path: %{type: :string, required: true},
      max_bytes: %{type: :integer, required: false}
    }
  end

  @impl true
  def run(args, opts) do
    with {:ok, path} <- Policy.resolve_workspace_path(Policy.arg(args, :path), opts),
         {:ok, stat} <- File.stat(path),
         :ok <- ensure_regular_file(stat),
         {:ok, content} <- File.read(path) do
      max_bytes = max_bytes(args, opts)
      {content, truncated?} = truncate(content, max_bytes)

      {:ok,
       %{
         path: Policy.relative_path(path, opts),
         content: content,
         bytes: byte_size(content),
         truncated?: truncated?
       }}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_regular_file(%File.Stat{type: :regular}), do: :ok
  defp ensure_regular_file(_stat), do: {:error, :not_regular_file}

  defp max_bytes(args, opts) do
    case Policy.arg(args, :max_bytes) || Keyword.get(opts, :max_file_bytes, 65_536) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _other -> 65_536
        end

      _value ->
        65_536
    end
  end

  defp truncate(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate(content, _max_bytes), do: {content, false}
end
