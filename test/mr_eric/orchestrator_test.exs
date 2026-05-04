defmodule MrEric.OrchestratorTest do
  use ExUnit.Case

  alias MrEric.Agent
  alias MrEric.Orchestrator
  alias MrEric.Orchestrator.ToolCallParser

  defmodule PromptCaptureProvider do
    @moduledoc false

    @behaviour MrEric.LLM.Provider

    @impl true
    def chat_completion(prompt, opts \\ []) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_prompt, Keyword.get(opts, :agent_name), prompt})

      cond do
        String.contains?(prompt, "Create a concise implementation plan") ->
          {:ok, "captured plan"}

        String.contains?(prompt, "Produce an implementation draft") ->
          {:ok, "captured draft"}

        String.contains?(prompt, "Review this draft") ->
          {:ok, "captured review"}

        String.contains?(prompt, "Synthesize the final answer") ->
          {:ok, "captured final"}

        true ->
          {:ok, "captured response"}
      end
    end

    @impl true
    def stream_completion(prompt, pid, opts \\ []) do
      {:ok, content} = chat_completion(prompt, opts)
      send(pid, {:chunk, content})
      send(pid, {:complete, :ok})
      :ok
    end

    @impl true
    def list_models(_provider, _opts \\ []), do: {:ok, [%{"id" => "capture"}]}
  end

  defmodule ExplodingRAG do
    @moduledoc false

    def context_for(task, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:rag_called, task})
      raise "RAG unavailable"
    end
  end

  defmodule ToolLoopProvider do
    @moduledoc false

    @behaviour MrEric.LLM.Provider

    @impl true
    def chat_completion(prompt, opts \\ []) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_prompt, Keyword.get(opts, :agent_name), prompt})

      cond do
        Keyword.get(opts, :agent_name) == "planner" and
            not String.contains?(prompt, "Tool results") ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 "id" => "call-plan-read",
                 "function" => %{
                   "name" => "file_read",
                   "arguments" => Jason.encode!(%{path: "note.txt"})
                 }
               }
             ]
           }}

        String.contains?(prompt, "Create a concise implementation plan") ->
          {:ok, "plan after tool"}

        String.contains?(prompt, "Produce an implementation draft") ->
          {:ok, "draft after tool"}

        String.contains?(prompt, "Review this draft") ->
          {:ok, "review after tool"}

        String.contains?(prompt, "Synthesize the final answer") ->
          {:ok, "final after tool"}

        true ->
          {:ok, "tool loop response"}
      end
    end

    @impl true
    def stream_completion(prompt, pid, opts \\ []) do
      {:ok, content} = chat_completion(prompt, opts)
      send(pid, {:chunk, inspect(content)})
      send(pid, {:complete, :ok})
      :ok
    end

    @impl true
    def list_models(_provider, _opts \\ []), do: {:ok, [%{"id" => "tool-loop"}]}
  end

  defmodule AlwaysToolProvider do
    @moduledoc false

    @behaviour MrEric.LLM.Provider

    @impl true
    def chat_completion(_prompt, opts \\ []) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_call, Keyword.get(opts, :agent_name)})

      {:ok,
       Jason.encode!(%{
         tool: "file_read",
         input: %{path: "note.txt"},
         reason: "Need the file before answering"
       })}
    end

    @impl true
    def stream_completion(prompt, pid, opts \\ []) do
      {:ok, content} = chat_completion(prompt, opts)
      send(pid, {:chunk, content})
      send(pid, {:complete, :ok})
      :ok
    end

    @impl true
    def list_models(_provider, _opts \\ []), do: {:ok, [%{"id" => "always-tool"}]}
  end

  defmodule OptionCaptureProvider do
    @moduledoc false

    @behaviour MrEric.LLM.Provider

    @impl true
    def chat_completion(prompt, opts \\ []) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:llm_opts, Keyword.get(opts, :agent_name), Keyword.has_key?(opts, :tools),
         Keyword.get(opts, :tool_choice)}
      )

      cond do
        String.contains?(prompt, "Create a concise implementation plan") ->
          {:ok, "option plan"}

        String.contains?(prompt, "Produce an implementation draft") ->
          {:ok, "option draft"}

        String.contains?(prompt, "Review this draft") ->
          {:ok, "option review"}

        String.contains?(prompt, "Synthesize the final answer") ->
          {:ok, "option final"}

        true ->
          {:ok, "option response"}
      end
    end

    @impl true
    def stream_completion(prompt, pid, opts \\ []) do
      {:ok, content} = chat_completion(prompt, opts)
      send(pid, {:chunk, content})
      send(pid, {:complete, :ok})
      :ok
    end

    @impl true
    def list_models(_provider, _opts \\ []), do: {:ok, [%{"id" => "option"}]}
  end

  @registry %{
    planner: [%{name: "planner", provider: :ollama, model: "planner-model"}],
    drafts: [
      %{name: "draft-good", provider: :ollama, model: "draft-model"},
      %{name: "draft-bad", provider: :ollama, model: "draft-model", fail: true}
    ],
    reviewers: [
      %{name: "review-good", provider: :ollama, model: "review-model"},
      %{name: "review-bad", provider: :ollama, model: "review-model", fail: true}
    ],
    synthesizer: [%{name: "synth", provider: :ollama, model: "synth-model"}]
  }

  @opts [
    registry: @registry,
    provider_module: MrEric.LLM.FakeProvider,
    max_concurrency: 4
  ]

  test "run/2 executes planner, draft agents, reviewers, and synthesizer" do
    assert {:ok, result} = Orchestrator.run("Build Phase 2", @opts)

    assert result.task == "Build Phase 2"
    assert result.plan == "plan from planner-model"
    assert result.final == "final from synth-model"
    assert [%{content: "draft from draft-good"}] = result.drafts
    assert [%{content: "review from review-good"}] = result.reviews
  end

  test "run/2 keeps going when some draft and review models fail" do
    assert {:ok, result} = Orchestrator.run("Build resilient flow", @opts)

    assert [%{agent: %{name: "draft-bad"}, reason: {:fake_failure, "draft-bad"}}] =
             result.draft_errors

    assert [%{agent: %{name: "review-bad"}, reason: {:fake_failure, "review-bad"}}] =
             result.review_errors

    assert result.final == "final from synth-model"
  end

  test "run/2 falls back to the best draft when synthesis fails" do
    registry =
      put_in(@registry, [:synthesizer], [%{name: "synth-bad", model: "synth", fail: true}])

    assert {:ok, result} =
             Orchestrator.run("Build with fallback", Keyword.put(@opts, :registry, registry))

    assert result.final == "draft from draft-good"

    assert %{agent: %{name: "synth-bad"}, reason: {:fake_failure, "synth-bad"}} =
             result.synthesis_error
  end

  test "run/2 includes RAG context in the planner prompt" do
    assert {:ok, result} =
             Orchestrator.run(
               "Explain approval policy",
               @opts
               |> Keyword.put(:provider_module, PromptCaptureProvider)
               |> Keyword.put(:test_pid, self())
               |> Keyword.put(
                 :rag_context,
                 "lib/mr_eric/tools/policy.ex: shell commands require approval"
               )
             )

    assert result.plan == "captured plan"
    assert result.final == "captured final"

    assert_received {:llm_prompt, "planner", planner_prompt}
    assert planner_prompt =~ "Project context"
    assert planner_prompt =~ "shell commands require approval"
  end

  test "run/2 still completes when RAG context lookup fails" do
    assert {:ok, result} =
             Orchestrator.run(
               "Build despite RAG failure",
               @opts ++ [rag_module: ExplodingRAG, test_pid: self()]
             )

    assert_received {:rag_called, "Build despite RAG failure"}
    assert result.final == "final from synth-model"
  end

  test "stream/3 includes RAG context in planner prompts" do
    assert {:ok, result} =
             Orchestrator.stream(
               "Explain approval policy",
               self(),
               @opts
               |> Keyword.put(:provider_module, PromptCaptureProvider)
               |> Keyword.put(:test_pid, self())
               |> Keyword.put(
                 :rag_context,
                 "lib/mr_eric/tools/policy.ex: shell commands require approval"
               )
             )

    assert result.final == "captured final"
    assert_received {:llm_prompt, "planner", planner_prompt}
    assert planner_prompt =~ "Project context"
    assert planner_prompt =~ "shell commands require approval"
  end

  test "stream/3 still completes when RAG context lookup fails" do
    assert {:ok, result} =
             Orchestrator.stream(
               "Stream despite RAG failure",
               self(),
               @opts ++ [rag_module: ExplodingRAG, test_pid: self()]
             )

    assert_received {:rag_called, "Stream despite RAG failure"}
    assert result.final == "final from synth-model"
  end

  test "detects OpenAI-compatible tool_calls" do
    result = %{
      content: nil,
      tool_calls: [
        %{
          "id" => "call-1",
          "function" => %{
            "name" => "file_read",
            "arguments" => ~s({"path":"lib/mr_eric/orchestrator.ex"})
          }
        }
      ]
    }

    assert [
             %{
               tool_call_id: "call-1",
               tool: "file_read",
               args: %{"path" => "lib/mr_eric/orchestrator.ex"}
             }
           ] = ToolCallParser.extract(result)
  end

  test "returns safe parse errors for invalid tool_call JSON" do
    result = %{
      tool_calls: [
        %{
          "id" => "call-bad-json",
          "function" => %{"name" => "file_read", "arguments" => "{not json"}
        }
      ]
    }

    assert [
             %{
               tool_call_id: "call-bad-json",
               tool: "file_read",
               error: :invalid_tool_arguments
             }
           ] = ToolCallParser.extract(result)
  end

  test "detects the internal text tool request format" do
    content =
      Jason.encode!(%{
        tool: "file_read",
        input: %{path: "lib/mr_eric/orchestrator.ex"},
        reason: "Need to inspect the orchestrator"
      })

    assert [
             %{
               tool: "file_read",
               args: %{"path" => "lib/mr_eric/orchestrator.ex"},
               reason: "Need to inspect the orchestrator"
             }
           ] = ToolCallParser.extract(%{content: content})
  end

  test "stream/3 sends tool requests and resumes with tool results" do
    parent = self()

    task =
      Task.async(fn ->
        Orchestrator.stream(
          "Read the project note",
          parent,
          @opts
          |> Keyword.put(:provider_module, ToolLoopProvider)
          |> Keyword.put(:test_pid, parent)
          |> Keyword.put(:rag_enabled, false)
        )
      end)

    assert_receive {:tool_requested,
                    %{
                      role: :planner,
                      tool_name: "file_read",
                      tool_call_id: "call-plan-read",
                      input: %{"path" => "note.txt"},
                      reply_to: reply_to
                    }}

    send(
      reply_to,
      {:tool_result,
       %{
         tool_call_id: "call-plan-read",
         tool: "file_read",
         status: :completed,
         result: %{path: "note.txt", content: "project note"}
       }}
    )

    assert_receive {:stage_completed, %{role: :planner, content: "plan after tool"}}
    assert_receive {:run_completed, %{final: "final after tool"}}
    assert {:ok, %{final: "final after tool"}} = Task.await(task)
  end

  test "stream/3 keeps tool results in the next prompt when context is long" do
    parent = self()
    long_task = String.duplicate("long task context ", 120)

    task =
      Task.async(fn ->
        Orchestrator.stream(
          long_task,
          parent,
          @opts
          |> Keyword.put(:provider_module, ToolLoopProvider)
          |> Keyword.put(:test_pid, parent)
          |> Keyword.put(:rag_enabled, false)
          |> Keyword.put(:max_context_chars, 500)
        )
      end)

    assert_receive {:llm_prompt, "planner", _first_prompt}

    assert_receive {:tool_requested,
                    %{
                      tool_call_id: "call-plan-read",
                      reply_to: reply_to
                    }}

    send(
      reply_to,
      {:tool_result,
       %{
         tool_call_id: "call-plan-read",
         tool: "file_read",
         status: :completed,
         result: %{path: "note.txt", content: "IMPORTANT_TOOL_RESULT"}
       }}
    )

    assert_receive {:llm_prompt, "planner", second_prompt}
    assert second_prompt =~ "IMPORTANT_TOOL_RESULT"
    assert_receive {:run_completed, %{final: "final after tool"}}
    assert {:ok, %{final: "final after tool"}} = Task.await(task)
  end

  test "stream/3 does not send native tool specs to local providers by default" do
    assert {:ok, %{final: "option final"}} =
             Orchestrator.stream(
               "Local provider fallback",
               self(),
               @opts
               |> Keyword.put(:provider_module, OptionCaptureProvider)
               |> Keyword.put(:test_pid, self())
               |> Keyword.put(:rag_enabled, false)
             )

    assert_received {:llm_opts, "planner", false, nil}
  end

  test "stream/3 stops requesting tools after max_tool_calls_per_run" do
    assert {:ok, result} =
             Orchestrator.stream(
               "Do not call tools",
               self(),
               @opts
               |> Keyword.put(:provider_module, AlwaysToolProvider)
               |> Keyword.put(:test_pid, self())
               |> Keyword.put(:rag_enabled, false)
               |> Keyword.put(:max_tool_calls_per_run, 0)
             )

    assert result.final =~ "tool"
    refute_receive {:tool_requested, _payload}, 100
  end

  test "Agent.execute/2 delegates to Orchestrator.run/2 and keeps code equal to final" do
    server = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, name: server})

    assert {:ok, entry} = Agent.execute("Keep UI compatible", Keyword.put(@opts, :server, server))

    assert entry.final == "final from synth-model"
    assert entry.code == entry.final
    assert entry.plan == "plan from planner-model"
  end
end
