defmodule MrEric.RAG.IndexTest do
  use ExUnit.Case, async: true

  alias MrEric.RAG.Index
  alias MrEric.RAG.Retriever

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-rag-index-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib/tools"))

    File.write!(
      Path.join(workspace, "lib/tools/policy.ex"),
      "approval gate keeps shell commands safe\nnever expose secrets\n"
    )

    File.write!(Path.join(workspace, "README.md"), "MrEric project notes about RAG search\n")
    File.write!(Path.join(workspace, ".env"), "OPENAI_API_KEY=sk-hidden")
    File.write!(Path.join(workspace, ".envrc"), "export OPENAI_API_KEY=sk-hidden-too")

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "builds a safe project index and skips secret paths", %{workspace: workspace} do
    assert {:ok, index} =
             Index.build(
               workspace_root: workspace,
               paths: ["lib/tools/policy.ex", "README.md", ".env"]
             )

    paths = Enum.map(index.chunks, & &1.path)

    assert "lib/tools/policy.ex" in paths
    assert "README.md" in paths
    refute ".env" in paths
    assert index.file_count == 2
    assert Enum.any?(index.errors, &(&1.path == ".env"))
  end

  test "skips .envrc and symlinks that escape the workspace", %{workspace: workspace} do
    File.ln_s!("/etc/passwd", Path.join(workspace, "passwd.txt"))

    assert {:ok, index} =
             Index.build(
               workspace_root: workspace,
               paths: [".envrc", "passwd.txt"]
             )

    assert index.chunks == []
    assert Enum.any?(index.errors, &(&1.path == ".envrc" and &1.reason == :secret_file))
    assert Enum.any?(index.errors, &(&1.path == "passwd.txt" and &1.reason == :outside_workspace))
  end

  test "retrieves relevant chunks from the index", %{workspace: workspace} do
    assert {:ok, index} = Index.build(workspace_root: workspace)

    assert [
             %{
               path: "lib/tools/policy.ex",
               content: content,
               score: score
             }
             | _
           ] = Retriever.search(index, "approval shell safety", top_k: 1)

    assert content =~ "approval gate"
    assert score > 0
  end
end
