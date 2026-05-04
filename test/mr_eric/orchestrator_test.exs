defmodule MrEric.OrchestratorTest do
  use ExUnit.Case

  alias MrEric.Agent
  alias MrEric.Orchestrator

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

  test "Agent.execute/2 delegates to Orchestrator.run/2 and keeps code equal to final" do
    server = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, name: server})

    assert {:ok, entry} = Agent.execute("Keep UI compatible", Keyword.put(@opts, :server, server))

    assert entry.final == "final from synth-model"
    assert entry.code == entry.final
    assert entry.plan == "plan from planner-model"
  end
end
