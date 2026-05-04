defmodule MrEric.Tools.FileWriteProposal do
  @moduledoc """
  Produces a proposed file write without modifying the filesystem.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @impl true
  def name, do: :file_write_proposal

  @impl true
  def description, do: "Prepare a file write proposal and diff without writing."

  @impl true
  def schema do
    %{
      path: %{type: :string, required: true},
      content: %{type: :string, required: true}
    }
  end

  @impl true
  def run(args, opts) do
    with {:ok, path} <- Policy.resolve_workspace_path(Policy.arg(args, :path), opts) do
      relative = Policy.relative_path(path, opts)
      proposed_content = to_string(Policy.arg(args, :content) || "")
      current_content = read_existing(path)

      {:ok,
       %{
         path: relative,
         proposed_content: proposed_content,
         diff: unified_diff(relative, current_content, proposed_content),
         writes_file?: false
       }}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, _reason} -> ""
    end
  end

  defp unified_diff(path, current, proposed) when current == proposed do
    "No changes for #{path}\n"
  end

  defp unified_diff(path, current, proposed) do
    old_lines = diff_lines(current)
    new_lines = diff_lines(proposed)

    Enum.join(
      ["--- a/#{path}", "+++ b/#{path}", "@@ -1 +1 @@"]
      |> Kernel.++(Enum.map(old_lines, &("-" <> &1)))
      |> Kernel.++(Enum.map(new_lines, &("+" <> &1))),
      "\n"
    ) <> "\n"
  end

  defp diff_lines(""), do: []
  defp diff_lines(content), do: String.split(content, "\n", trim: true)
end
