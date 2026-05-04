defmodule MrEric.RAGTest do
  use ExUnit.Case, async: true

  alias MrEric.RAG

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-rag-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib/mr_eric/tools"))

    File.write!(
      Path.join(workspace, "lib/mr_eric/tools/policy.ex"),
      """
      shell commands always require approval
      file paths must stay inside the workspace
      """
    )

    File.write!(Path.join(workspace, ".env"), "OPENAI_API_KEY=sk-hidden")

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "context_for/2 formats retrievable project context", %{workspace: workspace} do
    assert {:ok, context} =
             RAG.context_for("How does shell approval work?",
               workspace_root: workspace,
               rag_top_k: 2
             )

    assert context =~ "Project context"
    assert context =~ "lib/mr_eric/tools/policy.ex:1-"
    assert context =~ "shell commands always require approval"
    refute context =~ "sk-hidden"
  end
end
