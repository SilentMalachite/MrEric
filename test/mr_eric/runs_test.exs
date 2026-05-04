defmodule MrEric.RunsTest do
  use ExUnit.Case

  alias MrEric.Orchestrator
  alias MrEric.Runs
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunWorker

  defmodule ToolLoopOrchestrator do
    @moduledoc false

    def stream(task, pid, _opts) do
      tool =
        if String.contains?(task, "unknown") do
          "unknown_tool"
        else
          "shell_command"
        end

      send(
        pid,
        {:tool_requested,
         %{
           role: :planner,
           tool_name: tool,
           tool_call_id: "call-loop",
           input: %{command: "pwd"},
           reason: "Need current directory",
           reply_to: self()
         }}
      )

      receive do
        {:tool_result, %{tool_call_id: "call-loop", status: status} = result} ->
          send(pid, {:run_completed, %{final: "continued after #{status}", result: result}})
          {:ok, %{final: "continued after #{status}"}}
      after
        1_000 ->
          send(pid, {:run_failed, %{error: :tool_timeout}})
          {:error, :tool_timeout}
      end
    end
  end

  @registry %{
    planner: [%{name: "planner", provider: :ollama, model: "planner-model"}],
    drafts: [
      %{name: "draft-local", provider: :ollama, model: "local-model"},
      %{name: "draft-cloud", provider: :openai, model: "cloud-model", fail: true}
    ],
    reviewers: [
      %{name: "critic", provider: :ollama, model: "critic-model"},
      %{name: "reviewer", provider: :openai, model: "reviewer-model"}
    ],
    synthesizer: [%{name: "synth", provider: :ollama, model: "synth-model"}]
  }

  @opts [
    registry: @registry,
    provider_module: MrEric.LLM.FakeProvider,
    max_concurrency: 4
  ]

  test "start_run/2 starts a RunWorker and exposes the run state" do
    run_id = unique_run_id()

    assert {:ok, %Run{id: ^run_id}} = Runs.start_run("Build Phase 4", @opts ++ [id: run_id])

    assert {:ok, %Run{id: ^run_id, task: "Build Phase 4"}} = Runs.get_run(run_id)
  end

  test "subscribe/1 receives PubSub events broadcast for the run" do
    run_id = unique_run_id()

    assert :ok = Runs.subscribe(run_id)
    assert :ok = Runs.broadcast(run_id, {:stage_chunk, %{role: :planner, chunk: "hello"}})

    assert_receive {:stage_chunk, %{run_id: ^run_id, role: :planner, chunk: "hello"}}
  end

  test "RunWorker updates state and broadcasts stage chunks" do
    run = Run.new("Manual run", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(pid, {:stage_started, %{role: :planner}})
    send(pid, {:stage_chunk, %{role: :planner, chunk: "chunk A"}})

    assert_receive {:stage_chunk, %{run_id: run_id, role: :planner, chunk: "chunk A"}}
    assert run_id == run.id

    assert {:ok, updated} = RunWorker.get_run(pid)
    assert updated.stages.planner.status == :streaming
    assert updated.stages.planner.content == "chunk A"
  end

  test "RunWorker updates state and broadcasts stage failures" do
    run = Run.new("Manual failure", id: unique_run_id(), provider: :openai, model: "gpt-4o")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(pid, {:stage_started, %{role: :cloud_drafter}})
    send(pid, {:stage_failed, %{role: :cloud_drafter, error: :missing_api_key}})

    assert_receive {:stage_failed,
                    %{
                      run_id: run_id,
                      role: :cloud_drafter,
                      error: "The selected provider is missing its API key."
                    }}

    assert run_id == run.id

    assert {:ok, updated} = RunWorker.get_run(pid)
    assert updated.stages.cloud_drafter.status == :failed
    assert updated.stages.cloud_drafter.error == "The selected provider is missing its API key."
  end

  test "Orchestrator.stream/3 continues when one drafter fails" do
    Orchestrator.stream("Build resilient Phase 4", self(), @opts)

    assert_receive {:stage_failed, %{role: :cloud_drafter}}
    assert_receive {:stage_completed, %{role: :local_drafter}}
    assert_receive {:run_completed, %{final: "final from synth-model"}}
  end

  test "cancel_run/1 marks the run as cancelled" do
    run_id = unique_run_id()

    assert :ok = Runs.subscribe(run_id)

    assert {:ok, %Run{id: ^run_id}} =
             Runs.start_run("Long running task", @opts ++ [id: run_id, delay_ms: 1_000])

    assert_receive {:run_started, %{run_id: ^run_id}}

    assert :ok = Runs.cancel_run(run_id)
    assert_receive {:run_cancelled, %{run_id: ^run_id}}

    assert {:ok, %Run{status: :cancelled}} = Runs.get_run(run_id)
  end

  test "RunWorker requests approval before executing a shell tool" do
    run = Run.new("Manual tool run", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call, %{tool: :shell_command, tool_call_id: "call-1", args: %{command: "pwd"}}}
    )

    assert_receive {:tool_approval_requested,
                    %{
                      run_id: run_id,
                      tool: :shell_command,
                      tool_call_id: "call-1",
                      approval_id: approval_id,
                      args: %{command: "pwd"}
                    }}

    assert run_id == run.id
    refute_receive {:tool_completed, %{tool_call_id: "call-1"}}, 50
    assert {:ok, %Run{status: :waiting_for_approval}} = RunWorker.get_run(pid)

    assert :ok = RunWorker.approve_tool(pid, approval_id)
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_id, approved: true}}
    assert_receive {:tool_started, %{tool_call_id: "call-1", tool: :shell_command}}
    assert_receive {:tool_completed, %{tool_call_id: "call-1", result: %{exit_status: 0}}}
  end

  test "RunWorker records changed files from approved apply_patch tools in history" do
    workspace = tmp_workspace()
    File.write!(Path.join(workspace, "note.txt"), "old\n")
    assert {_, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)

    agent_server = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Agent, name: agent_server})

    run = Run.new("Patch run", id: unique_run_id(), provider: :ollama, model: "llama3.1")

    assert {:ok, pid} =
             RunWorker.start_link(
               run: run,
               opts: [workspace_root: workspace, agent_server: agent_server],
               auto_start: false,
               name: nil
             )

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call,
       %{
         tool: :apply_patch,
         tool_call_id: "patch-call",
         args: %{changes: [%{path: "note.txt", before: "old\n", after: "new\n"}]}
       }}
    )

    assert_receive {:tool_approval_requested,
                    %{tool: :apply_patch, approval_id: approval_id, risk_level: :high}}

    assert :ok = RunWorker.approve_tool(pid, approval_id)
    assert_receive {:tool_completed, %{tool_call_id: "patch-call", result: result}}
    assert result.changed_files == ["note.txt"]
    assert result.git_diff =~ "+new"

    assert {:ok, %Run{changed_files: ["note.txt"]}} = RunWorker.get_run(pid)

    send(pid, {:run_completed, %{final: "patched"}})
    assert_receive {:run_completed, %{final: "patched"}}

    assert [%{changed_files: ["note.txt"]} | _] = MrEric.Agent.history(agent_server)
  end

  test "RunWorker broadcasts rejected tool approvals without execution" do
    run = Run.new("Manual denied tool", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call, %{tool: :shell_command, tool_call_id: "call-denied", args: %{command: "pwd"}}}
    )

    assert_receive {:tool_approval_requested, %{approval_id: approval_id}}

    assert :ok = RunWorker.deny_tool(pid, approval_id)
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_id, approved: false}}
    assert_receive {:tool_rejected, %{tool_call_id: "call-denied", error: "Tool request denied."}}
    refute_receive {:tool_started, %{tool_call_id: "call-denied"}}, 50
  end

  test "RunWorker continues an orchestrator loop after approving a tool" do
    run = Run.new("approval loop", id: unique_run_id(), provider: :ollama, model: "llama3.1")

    assert {:ok, pid} =
             RunWorker.start_link(
               run: run,
               opts: [orchestrator_module: ToolLoopOrchestrator, skip_history: true],
               name: nil
             )

    assert :ok = Runs.subscribe(run.id)
    assert_receive {:tool_approval_requested, %{approval_id: approval_id, role: :planner}}
    assert {:ok, %Run{status: :waiting_for_approval}} = RunWorker.get_run(pid)

    assert :ok = RunWorker.approve_tool(pid, approval_id)
    assert_receive {:tool_completed, %{tool_call_id: "call-loop", result: %{exit_status: 0}}}
    assert_receive {:run_completed, %{final: "continued after completed"}}

    assert {:ok, %Run{status: :completed, final: "continued after completed"}} =
             RunWorker.get_run(pid)
  end

  test "RunWorker stays waiting while other tool approvals remain pending" do
    run = Run.new("Two approvals", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_requested,
       %{
         role: :critic,
         tool_name: :shell_command,
         tool_call_id: "call-one",
         input: %{command: "pwd"},
         reply_to: self()
       }}
    )

    send(
      pid,
      {:tool_requested,
       %{
         role: :reviewer,
         tool_name: :shell_command,
         tool_call_id: "call-two",
         input: %{command: "pwd"},
         reply_to: self()
       }}
    )

    assert_receive {:tool_approval_requested,
                    %{tool_call_id: "call-one", approval_id: approval_one}}

    assert_receive {:tool_approval_requested,
                    %{tool_call_id: "call-two", approval_id: approval_two}}

    assert {:ok, %Run{status: :waiting_for_approval}} = RunWorker.get_run(pid)

    assert :ok = RunWorker.approve_tool(pid, approval_one)
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_one, approved: true}}
    assert {:ok, %Run{status: :waiting_for_approval}} = RunWorker.get_run(pid)

    assert :ok = RunWorker.deny_tool(pid, approval_two)
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_two, approved: false}}
    assert {:ok, %Run{status: :running}} = RunWorker.get_run(pid)
  end

  test "RunWorker returns a rejected result and continues after rejecting approval" do
    run = Run.new("reject loop", id: unique_run_id(), provider: :ollama, model: "llama3.1")

    assert {:ok, pid} =
             RunWorker.start_link(
               run: run,
               opts: [orchestrator_module: ToolLoopOrchestrator, skip_history: true],
               name: nil
             )

    assert :ok = Runs.subscribe(run.id)
    assert_receive {:tool_approval_requested, %{approval_id: approval_id}}

    assert :ok = RunWorker.deny_tool(pid, approval_id)
    assert_receive {:tool_rejected, %{tool_call_id: "call-loop"}}
    assert_receive {:run_completed, %{final: "continued after rejected"}}

    assert {:ok, %Run{status: :completed, final: "continued after rejected"}} =
             RunWorker.get_run(pid)
  end

  test "RunWorker denies unknown tools and returns the denial to the orchestrator" do
    run = Run.new("unknown tool loop", id: unique_run_id(), provider: :ollama, model: "llama3.1")

    assert {:ok, _pid} =
             RunWorker.start_link(
               run: run,
               opts: [orchestrator_module: ToolLoopOrchestrator, skip_history: true],
               name: nil
             )

    assert :ok = Runs.subscribe(run.id)
    assert_receive {:tool_denied, %{tool_call_id: "call-loop", error: "Tool request denied."}}
    assert_receive {:run_completed, %{final: "continued after denied"}}
  end

  test "RunWorker sends completed tool results back to the requesting process" do
    workspace = tmp_workspace()
    File.write!(Path.join(workspace, "note.txt"), "hello from tool result")

    run = Run.new("Manual tool reply", id: unique_run_id(), provider: :ollama, model: "llama3.1")

    assert {:ok, pid} =
             RunWorker.start_link(
               run: run,
               opts: [workspace_root: workspace],
               auto_start: false,
               name: nil
             )

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call,
       %{
         tool: :file_read,
         tool_call_id: "call-reply",
         args: %{path: "note.txt"},
         reply_to: self()
       }}
    )

    assert_receive {:tool_started, %{tool_call_id: "call-reply", tool: :file_read}}
    assert_receive {:tool_completed, %{tool_call_id: "call-reply"}}

    assert_receive {:tool_result,
                    %{
                      tool_call_id: "call-reply",
                      tool: :file_read,
                      status: :completed,
                      result: %{content: "hello from tool result"}
                    }}
  end

  test "tool events redact API keys before broadcasting" do
    run_id = unique_run_id()
    assert :ok = Runs.subscribe(run_id)

    assert :ok =
             Runs.broadcast(
               run_id,
               {:tool_completed,
                %{
                  tool: :shell_command,
                  tool_call_id: "secret-call",
                  result: %{output: "OPENAI_API_KEY=sk-secret123"}
                }}
             )

    assert_receive {:tool_completed, %{result: %{output: output}}}
    refute output =~ "sk-secret123"
    assert output =~ "[REDACTED]"
  end

  test "tool events redact secret values based on payload keys" do
    run_id = unique_run_id()
    assert :ok = Runs.subscribe(run_id)

    assert :ok =
             Runs.broadcast(
               run_id,
               {:tool_completed,
                %{
                  tool: :shell_command,
                  tool_call_id: "secret-key-call",
                  result: %{
                    authorization: "Bearer raw-token",
                    cookie: "session=raw-cookie",
                    nested: %{api_key: "raw-api-key"}
                  }
                }}
             )

    assert_receive {:tool_completed, %{result: result}}
    assert result.authorization == "[REDACTED]"
    assert result.cookie == "[REDACTED]"
    assert result.nested.api_key == "[REDACTED]"
  end

  test "RunWorker clears pending tool approvals after terminal events" do
    run = Run.new("Terminal tool run", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call,
       %{tool: :shell_command, tool_call_id: "call-terminal", args: %{command: "pwd"}}}
    )

    assert_receive {:tool_approval_requested, %{approval_id: approval_id}}

    send(pid, {:run_completed, %{final: "done"}})
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_id, approved: false}}
    assert_receive {:run_completed, %{final: "done"}}

    assert {:error, :not_found} = RunWorker.approve_tool(pid, approval_id)
    refute_receive {:tool_started, %{tool_call_id: "call-terminal"}}, 50
  end

  test "RunWorker resolves pending tool approvals when cancelled" do
    run = Run.new("Cancelled tool run", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(
      pid,
      {:tool_call,
       %{tool: :shell_command, tool_call_id: "call-cancelled", args: %{command: "pwd"}}}
    )

    assert_receive {:tool_approval_requested, %{approval_id: approval_id}}

    assert :ok = RunWorker.cancel(pid)
    assert_receive {:tool_approval_resolved, %{approval_id: ^approval_id, approved: false}}
    assert_receive {:run_cancelled, %{run_id: run_id}}
    assert run_id == run.id

    assert {:error, :not_found} = RunWorker.approve_tool(pid, approval_id)
    refute_receive {:tool_started, %{tool_call_id: "call-cancelled"}}, 50
  end

  defp unique_run_id do
    "run-test-#{System.unique_integer([:positive])}"
  end

  defp tmp_workspace do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-run-worker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    workspace
  end
end
