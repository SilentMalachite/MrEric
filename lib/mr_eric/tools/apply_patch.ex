defmodule MrEric.Tools.ApplyPatch do
  @moduledoc """
  Applies an approved patch proposal inside the configured workspace.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.PatchResult
  alias MrEric.Tools.PatchValidator
  alias MrEric.Tools.Policy

  @impl true
  def name, do: :apply_patch

  @impl true
  def description, do: "Apply an approved text patch inside the workspace and return git diff."

  @impl true
  def schema do
    %{
      path: %{type: :string, required: false},
      patch: %{type: :string, required: false},
      changes: %{type: :array, required: false}
    }
  end

  @impl true
  def run(args, opts) do
    with {:ok, proposal} <- PatchValidator.validate(args, opts),
         :ok <- apply_proposal(proposal, opts) do
      {:ok, PatchResult.success(proposal, git_diff(proposal.changed_files, opts))}
    end
  end

  defp apply_proposal(%{mode: :changes, changes: changes}, _opts) do
    Enum.each(changes, fn change ->
      change.full_path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(change.full_path, change.after_content)
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp apply_proposal(%{mode: :unified_diff, patch: patch}, opts) do
    with_patch_file(patch, fn patch_path ->
      workspace = Policy.workspace_root(opts)

      case System.cmd("git", ["apply", "--whitespace=nowarn", patch_path],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> {:error, :before_mismatch}
      end
    end)
  end

  defp git_diff(paths, opts) do
    workspace = Policy.workspace_root(opts)
    args = ["diff", "--"] ++ paths

    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, _status} -> output
    end
  rescue
    error -> Exception.message(error)
  end

  defp with_patch_file(patch, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "mr-eric-apply-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}.diff"
      )

    File.write!(path, patch)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
