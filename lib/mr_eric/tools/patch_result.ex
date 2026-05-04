defmodule MrEric.Tools.PatchResult do
  @moduledoc """
  Shapes public results for approved patch application.
  """

  def success(proposal, git_diff) do
    %{
      applied?: true,
      changed_files: proposal.changed_files,
      summary: proposal.summary,
      diff: proposal.diff,
      git_diff: git_diff,
      rollback: %{
        mode: :manual_git_diff_revert,
        scope: :workspace,
        instructions:
          "Review the git diff shown here and revert the affected files from the Codex diff pane if needed."
      }
    }
  end
end
