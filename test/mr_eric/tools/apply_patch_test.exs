defmodule MrEric.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.ApplyPatch
  alias MrEric.Tools.PatchValidator

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-apply-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    outside =
      Path.join(System.tmp_dir!(), "mr-eric-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    {:ok, workspace: workspace, outside: outside}
  end

  test "applies a changes proposal", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.write!(Path.join(workspace, "notes/task.md"), "old\n")

    assert {:ok, result} =
             ApplyPatch.run(
               %{changes: [%{path: "notes/task.md", before: "old\n", after: "new\n"}]},
               workspace_root: workspace
             )

    assert result.applied? == true
    assert result.changed_files == ["notes/task.md"]
    assert File.read!(Path.join(workspace, "notes/task.md")) == "new\n"
  end

  test "refuses to write when a path segment becomes a symlink after validation", %{
    workspace: workspace,
    outside: outside
  } do
    File.write!(Path.join(outside, "task.md"), "outside\n")

    notes = Path.join(workspace, "notes")
    File.mkdir_p!(notes)
    File.write!(Path.join(notes, "task.md"), "old\n")

    args = %{changes: [%{path: "notes/task.md", before: "old\n", after: "new\n"}]}
    opts = [workspace_root: workspace]

    # Validation passes while `notes` is still a real directory.
    assert {:ok, proposal} = PatchValidator.validate(args, opts)

    # Swap the directory for a symlink pointing outside the workspace.
    File.rm_rf!(notes)
    File.ln_s!(outside, notes)

    assert {:error, :outside_workspace} = ApplyPatch.apply_validated(proposal, opts)
    assert File.read!(Path.join(outside, "task.md")) == "outside\n"
  end

  test "a multi-change proposal halts on the first re-resolution failure", %{
    workspace: workspace,
    outside: outside
  } do
    File.write!(Path.join(outside, "second.md"), "outside\n")

    File.write!(Path.join(workspace, "first.md"), "old-first\n")
    nested = Path.join(workspace, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "second.md"), "old-second\n")

    args = %{
      changes: [
        %{path: "first.md", before: "old-first\n", after: "new-first\n"},
        %{path: "nested/second.md", before: "old-second\n", after: "new-second\n"}
      ]
    }

    opts = [workspace_root: workspace]

    assert {:ok, proposal} = PatchValidator.validate(args, opts)

    File.rm_rf!(nested)
    File.ln_s!(outside, nested)

    assert {:error, :outside_workspace} = ApplyPatch.apply_validated(proposal, opts)

    # apply_patch has never been atomic; rollback is manual via git diff.
    assert File.read!(Path.join(workspace, "first.md")) == "new-first\n"
    assert File.read!(Path.join(outside, "second.md")) == "outside\n"
  end
end
