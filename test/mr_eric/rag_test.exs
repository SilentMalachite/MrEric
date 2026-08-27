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

  test "a second lookup on an unchanged workspace does not rebuild", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    opts = [workspace_root: workspace]

    assert {:ok, first} = RAG.context_for("How does shell approval work?", opts)
    assert {:ok, _cached} = RAG.context_for("How does shell approval work?", opts)

    key = MrEric.RAG.Cache.key(opts)
    assert {:ok, fingerprint, _paths} = MrEric.RAG.Index.fingerprint(opts)
    assert {:ok, index} = MrEric.RAG.Cache.fetch(key, fingerprint)
    assert is_list(index.chunks)

    assert {:ok, ^first} = RAG.context_for("How does shell approval work?", opts)
  end

  test "editing an indexed file invalidates the cached index", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    opts = [workspace_root: workspace]
    assert {:ok, _first} = RAG.context_for("shell approval", opts)
    assert {:ok, before_fingerprint, _} = MrEric.RAG.Index.fingerprint(opts)

    File.write!(
      Path.join(workspace, "lib/mr_eric/tools/policy.ex"),
      "shell commands always require approval and now mention caching\n"
    )

    assert {:ok, later_fingerprint, _} = MrEric.RAG.Index.fingerprint(opts)
    refute before_fingerprint == later_fingerprint

    assert {:ok, context} = RAG.context_for("caching", opts)
    assert context =~ "caching"
  end

  test "a secret-inclusive index is never served to a safe caller", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    # `.env` is excluded by extension *and* by filename whatever
    # allow_secret_paths says, so it cannot tell the two indexes apart. A file
    # under `config/` can: that directory is in @default_ignored_dirs and is
    # removed from the ignore set only when allow_secret_paths is true.
    #
    # The name matters. `Index.index_path/3` reads through
    # `Policy.resolve_workspace_path/2`, which rejects any relative path
    # matching /secret|credential|token/ regardless of allow_secret_paths -- so
    # a `config/dev.secret.exs` canary would be absent from *both* indexes and
    # the guard below would pass for the wrong reason.
    File.mkdir_p!(Path.join(workspace, "config"))

    File.write!(
      Path.join(workspace, "config/canary.exs"),
      ~s(import Config\nconfig :mr_eric, marker: "phase-e-cache-key-canary"\n)
    )

    permissive = [workspace_root: workspace, allow_secret_paths: true]
    safe = [workspace_root: workspace]

    # Warm the cache with the permissive index first, and prove it really does
    # contain the canary -- otherwise the assertion below passes for the wrong
    # reason.
    assert {:ok, permissive_context} = RAG.context_for("cache key canary", permissive)
    assert permissive_context =~ "phase-e-cache-key-canary"

    assert {:ok, safe_context} = RAG.context_for("cache key canary", safe)
    refute safe_context =~ "phase-e-cache-key-canary"

    # And the two live under different keys rather than one having evicted the
    # other.
    refute MrEric.RAG.Cache.key(permissive) == MrEric.RAG.Cache.key(safe)
  end
end
