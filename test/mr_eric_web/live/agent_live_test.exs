defmodule MrEricWeb.AgentLiveTest do
  use MrEricWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    previous_run_opts = Application.get_env(:mr_eric, :live_run_opts, [])
    Application.put_env(:mr_eric, :live_run_opts, provider_module: MrEric.LLM.FakeProvider)

    on_exit(fn ->
      Application.put_env(:mr_eric, :live_run_opts, previous_run_opts)
    end)
  end

  test "renders agent interface", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "MrEric AI Agent"
    assert html =~ "Provider"
    assert html =~ "Model"
    assert has_element?(view, "#task-form")
    assert has_element?(view, "#provider-select")
    assert has_element?(view, "#model-select")
    assert has_element?(view, "#current-run")
    assert has_element?(view, "#stage-planner")
    assert has_element?(view, "#stage-local_drafter")
    assert has_element?(view, "#stage-cloud_drafter")
    assert has_element?(view, "#stage-critic")
    assert has_element?(view, "#stage-reviewer")
    assert has_element?(view, "#stage-synthesizer")
    assert has_element?(view, "#stage-final")
  end

  test "displays provider and model selection dropdowns", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "select[name='provider']")
    assert has_element?(view, "option[value='openai']")
    assert has_element?(view, "option[value='ollama']")
    assert has_element?(view, "option[value='lmstudio']")

    assert has_element?(view, "#model-select")
    assert has_element?(view, "option[value='gpt-4o']")
    refute has_element?(view, "option[value='llama3.1']")
  end

  test "changes provider selection and refreshes models", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#provider-select")
    |> render_change(%{"provider" => "ollama"})

    assert has_element?(view, "option[value='llama3.1']")
    assert render(view) =~ "ollama"
    assert render(view) =~ "llama3.1"
  end

  test "changes model selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#model-select")
    |> render_change(%{"model" => "gpt-4o-mini"})

    html = render(view)
    assert html =~ "gpt-4o-mini"
  end

  test "starts a run with the selected provider and model", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#provider-select")
    |> render_change(%{"provider" => "ollama"})

    view
    |> element("#model-select")
    |> render_change(%{"model" => "llama3.1"})

    view
    |> form("#task-form", %{"task" => "report provider"})
    |> render_submit()

    assert_eventually(fn ->
      html = render(view)
      html =~ "provider:ollama model:llama3.1" and html =~ "Current Run"
    end)

    html = render(view)
    assert html =~ "Run ID"
    assert html =~ "Planner"
    assert html =~ "Local Drafter"
    assert html =~ "Cloud Drafter"
    assert html =~ "Critic"
    assert html =~ "Reviewer"
    assert html =~ "Synthesizer"
    assert html =~ "Final"
  end

  test "shows run progress when executing task", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Test task"})
    |> render_submit()

    assert_eventually(fn ->
      html = render(view)
      html =~ "plan from gpt-4o" and html =~ "final from gpt-4o"
    end)
  end

  test "cancels the current run", %{conn: conn} do
    previous_run_opts = Application.get_env(:mr_eric, :live_run_opts, [])

    Application.put_env(:mr_eric, :live_run_opts,
      provider_module: MrEric.LLM.FakeProvider,
      delay_ms: 1_000
    )

    on_exit(fn ->
      Application.put_env(:mr_eric, :live_run_opts, previous_run_opts)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Slow task"})
    |> render_submit()

    assert_eventually(fn -> has_element?(view, "#cancel-run-button") end)

    view
    |> element("#cancel-run-button")
    |> render_click()

    assert_eventually(fn -> render(view) =~ "cancelled" end)
  end

  test "renders a recoverable error when the selected LLM is unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    send(view.pid, {:run_failed, %{run_id: nil, error: :econnrefused}})

    html = render(view)
    assert html =~ "The selected LLM provider is unavailable"
    assert has_element?(view, "#task-form")
  end

  test "renders approval UI for pending tool calls and approves them", %{conn: conn} do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-live-tools-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    previous_run_opts = Application.get_env(:mr_eric, :live_run_opts, [])

    Application.put_env(:mr_eric, :live_run_opts,
      orchestrator_module: MrEric.ToolRequestOrchestrator,
      workspace_root: workspace
    )

    on_exit(fn ->
      Application.put_env(:mr_eric, :live_run_opts, previous_run_opts)
      File.rm_rf!(workspace)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Needs shell"})
    |> render_submit()

    assert_eventually(fn -> has_element?(view, "#tool-approval-call-live") end)
    assert render(view) =~ "pwd"

    view
    |> element("#approve-tool-call-live")
    |> render_click()

    assert_eventually(fn ->
      has_element?(view, "#tool-event-call-live-completed") and render(view) =~ "exit_status: 0"
    end)
  end

  test "renders patch approval details and applies an approved patch", %{conn: conn} do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-live-patch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "old\n")
    assert {_, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)

    previous_run_opts = Application.get_env(:mr_eric, :live_run_opts, [])

    Application.put_env(:mr_eric, :live_run_opts,
      orchestrator_module: MrEric.ToolRequestOrchestrator,
      workspace_root: workspace
    )

    on_exit(fn ->
      Application.put_env(:mr_eric, :live_run_opts, previous_run_opts)
      File.rm_rf!(workspace)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Needs patch"})
    |> render_submit()

    assert_eventually(fn -> has_element?(view, "#tool-approval-call-live-patch") end)

    html = render(view)
    assert html =~ "Pending Patch Approval"
    assert html =~ "note.txt"
    assert html =~ "new from patch"
    assert html =~ "risk: high"

    view
    |> element("#approve-tool-call-live-patch")
    |> render_click()

    assert_eventually(fn ->
      has_element?(view, "#tool-event-call-live-patch-completed") and
        render(view) =~ "git diff"
    end)

    assert File.read!(Path.join(workspace, "note.txt")) == "new from patch\n"
  end

  test "renders target files from patch-only approval payloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    patch = """
    --- a/note.txt
    +++ b/note.txt
    @@ -1 +1 @@
    -old
    +new
    """

    send(
      view.pid,
      {:tool_approval_requested,
       %{
         run_id: nil,
         approval_id: "approval-patch-only-live",
         tool_call_id: "patch-only-live",
         tool: :apply_patch,
         role: :planner,
         risk_level: :high,
         reason: "Patch review",
         args: %{patch: patch}
       }}
    )

    assert_eventually(fn -> has_element?(view, "#tool-approval-patch-only-live") end)

    html = render(view)
    assert html =~ "note.txt"
    assert html =~ "1 file will change"
    refute html =~ "unknown"
    refute html =~ "0 files will change"
  end

  test "rejects a pending patch without modifying the file", %{conn: conn} do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "mr-eric-live-patch-reject-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "old\n")

    previous_run_opts = Application.get_env(:mr_eric, :live_run_opts, [])

    Application.put_env(:mr_eric, :live_run_opts,
      orchestrator_module: MrEric.ToolRequestOrchestrator,
      workspace_root: workspace
    )

    on_exit(fn ->
      Application.put_env(:mr_eric, :live_run_opts, previous_run_opts)
      File.rm_rf!(workspace)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Reject patch"})
    |> render_submit()

    assert_eventually(fn -> has_element?(view, "#tool-approval-call-live-patch") end)

    view
    |> element("#deny-tool-call-live-patch")
    |> render_click()

    assert_eventually(fn -> has_element?(view, "#tool-event-call-live-patch-rejected") end)
    assert File.read!(Path.join(workspace, "note.txt")) == "old\n"
  end

  test "redacts secrets from approval UI payloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    send(
      view.pid,
      {:tool_approval_requested,
       %{
         run_id: nil,
         approval_id: "approval-secret-live",
         tool_call_id: "secret-live",
         tool: :shell_command,
         role: :planner,
         risk_level: :high,
         reason: "Authorization: Bearer raw-token",
         args: %{command: "pwd", api_key: "sk-live-secret"}
       }}
    )

    assert_eventually(fn -> has_element?(view, "#tool-approval-secret-live") end)

    html = render(view)
    assert html =~ "planner / risk: high"
    refute html =~ "sk-live-secret"
    refute html =~ "raw-token"
    assert html =~ "[REDACTED]"
  end

  test "mount succeeds when EnsureOwnerId plug supplies owner_id", %{conn: conn} do
    # If EnsureOwnerId is not wired into :browser, mount/3 raises and
    # live/2 propagates the error.
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "MrEric AI Agent"
  end

  test "mount/3 raises when session has no owner_id" do
    # `live(conn, "/")` always goes through the :browser pipeline, which
    # would mint an owner_id. To verify the defensive raise we call
    # mount/3 directly with an empty session map.
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }

    assert_raise RuntimeError, ~r/owner_id missing from session/, fn ->
      MrEricWeb.AgentLive.mount(%{}, %{}, socket)
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0) do
    assert fun.()
  end
end
