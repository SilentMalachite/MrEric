defmodule MrEric.LLM.FakeProvider do
  @moduledoc """
  Deterministic provider used by tests and Phase 9 evals.

  It never performs network I/O. Responses are derived only from the prompt and
  explicit options such as `:script`, `:scenario`, `:role`, and `:fail_role`.
  """

  @behaviour MrEric.LLM.Provider

  @impl true
  def chat_completion(prompt, opts \\ []) do
    maybe_sleep(opts)

    role = role_for(prompt, opts)

    cond do
      Keyword.get(opts, :fail, false) ->
        {:error, {:fake_failure, Keyword.get(opts, :agent_name, role)}}

      fail_role?(role, opts) ->
        {:error, {:fake_failure, role}}

      scripted = scripted_response(role, opts) ->
        normalize_scripted_response(scripted)

      true ->
        scenario_response(prompt, role, opts)
    end
  end

  @impl true
  def stream_completion(prompt, pid, opts \\ []) do
    chunks = Keyword.get(opts, :stream_chunks)

    case chat_completion(prompt, opts) do
      {:ok, response} ->
        response_chunks(response, chunks)
        |> Enum.each(&send(pid, {:chunk, &1}))

        send(pid, {:complete, :ok})
        :ok

      {:error, reason} ->
        send(pid, {:agent_error, reason})
        :ok
    end
  end

  @impl true
  def list_models(_provider, _opts \\ []) do
    {:ok,
     [
       %{"id" => "fake-model", "owned_by" => "mr_eric"},
       %{"id" => "fake-tool-model", "owned_by" => "mr_eric"}
     ]}
  end

  defp scenario_response(prompt, role, opts) do
    scenario = normalize_name(Keyword.get(opts, :scenario))

    cond do
      scenario == "provider_missing_api_key_error" and role == :planner ->
        {:error, :missing_api_key}

      scenario == "mcp_unavailable_is_safe" and role == :planner ->
        {:error, :mcp_unavailable}

      scenario == "error" ->
        {:error, {:fake_failure, role}}

      tool_scenario?(scenario) and tool_request_phase?(prompt, role) ->
        {:ok, %{content: "", tool_calls: [tool_call_for(scenario)]}}

      scenario == "rag_context_used" and role == :planner ->
        if String.contains?(prompt, "phase9-rag-context") do
          {:ok, "plan with rag context for implementation"}
        else
          {:error, :rag_failed}
        end

      scenario == "secret_leak_check" and role == :synthesizer ->
        {:ok, "final includes OPENAI_API_KEY=sk-phase9dummysecret123456789"}

      scenario in [
        "simple_planning",
        "local_model_failure_continues",
        "rag_context_used",
        "rag_failure_does_not_break_run",
        "mcp_disabled_is_not_called"
      ] ->
        {:ok, scenario_content(scenario, role)}

      scenario in [
        "tool_denied",
        "tool_approval_required",
        "tool_approval_rejected",
        "patch_proposal_requires_approval",
        "patch_apply_after_approval"
      ] ->
        {:ok, scenario_content(scenario, role)}

      true ->
        default_response(prompt, opts)
    end
  end

  defp default_response(prompt, opts) do
    name = Keyword.get(opts, :agent_name, "agent")
    model = Keyword.get(opts, :model, "model")
    provider = Keyword.get(opts, :provider, "provider")

    cond do
      String.contains?(prompt, "report provider") ->
        {:ok, "provider:#{provider} model:#{model}"}

      String.contains?(prompt, "Create a concise implementation plan") ->
        {:ok, "plan from #{model}"}

      String.contains?(prompt, "Produce an implementation draft") ->
        {:ok, "draft from #{name}"}

      String.contains?(prompt, "Review this draft") ->
        {:ok, "review from #{name}"}

      String.contains?(prompt, "Synthesize the final answer") ->
        {:ok, "final from #{model}"}

      true ->
        {:ok, "response from #{name}"}
    end
  end

  defp scenario_content("local_model_failure_continues", :planner),
    do: "plan: implementation can continue with the cloud drafter"

  defp scenario_content("local_model_failure_continues", :synthesizer),
    do: "final plan and implementation completed despite a local model failure"

  defp scenario_content("rag_context_used", :synthesizer),
    do: "final plan and implementation used rag context"

  defp scenario_content("rag_failure_does_not_break_run", :synthesizer),
    do: "final plan and implementation continued after rag failure"

  defp scenario_content("mcp_disabled_is_not_called", :synthesizer),
    do: "final plan and implementation without mcp calls"

  defp scenario_content(scenario, :planner)
       when scenario in ["tool_denied", "tool_approval_required", "tool_approval_rejected"],
       do: "plan after tool result for #{scenario}"

  defp scenario_content(scenario, :planner)
       when scenario in ["patch_proposal_requires_approval", "patch_apply_after_approval"],
       do: "plan after patch tool result for #{scenario}"

  defp scenario_content(scenario, :synthesizer)
       when scenario in ["tool_denied", "tool_approval_required", "tool_approval_rejected"],
       do: "final plan and implementation after #{scenario}"

  defp scenario_content(scenario, :synthesizer)
       when scenario in ["patch_proposal_requires_approval", "patch_apply_after_approval"],
       do: "final plan and implementation after #{scenario}"

  defp scenario_content(_scenario, :planner), do: "plan: implementation steps"
  defp scenario_content(_scenario, :local_drafter), do: "local implementation draft"
  defp scenario_content(_scenario, :cloud_drafter), do: "cloud implementation draft"
  defp scenario_content(_scenario, :critic), do: "critic review"
  defp scenario_content(_scenario, :reviewer), do: "reviewer review"
  defp scenario_content(_scenario, :synthesizer), do: "final plan and implementation"
  defp scenario_content(_scenario, _role), do: "fake response"

  defp tool_scenario?(scenario) do
    scenario in [
      "tool_denied",
      "tool_approval_required",
      "tool_approval_rejected",
      "patch_proposal_requires_approval",
      "patch_apply_after_approval"
    ]
  end

  defp tool_request_phase?(prompt, role) do
    role in [:planner, :critic, :reviewer] and
      not String.contains?(prompt, "Tool results")
  end

  defp tool_call_for("tool_denied") do
    openai_tool_call("phase9-denied", "phase9_unknown_tool", %{})
  end

  defp tool_call_for("tool_approval_required") do
    openai_tool_call("phase9-shell", "shell_command", %{command: "pwd"})
  end

  defp tool_call_for("tool_approval_rejected") do
    openai_tool_call("phase9-shell-rejected", "shell_command", %{command: "pwd"})
  end

  defp tool_call_for("patch_proposal_requires_approval") do
    patch_tool_call("phase9-patch-required")
  end

  defp tool_call_for("patch_apply_after_approval") do
    patch_tool_call("phase9-patch-apply")
  end

  defp tool_call_for(_scenario),
    do: openai_tool_call("phase9-read", "file_read", %{path: "note.txt"})

  defp patch_tool_call(id) do
    openai_tool_call(id, "apply_patch", %{
      changes: [
        %{path: "note.txt", before: "old\n", after: "new from phase9\n"}
      ]
    })
  end

  defp openai_tool_call(id, name, arguments) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(arguments)
      }
    }
  end

  defp role_for(prompt, opts) do
    Keyword.get(opts, :role) ||
      role_from_agent_name(Keyword.get(opts, :agent_name)) ||
      role_from_prompt(prompt)
  end

  defp role_from_agent_name(name) when is_binary(name) do
    downcased = String.downcase(name)

    cond do
      String.contains?(downcased, "planner") -> :planner
      String.contains?(downcased, "local") -> :local_drafter
      String.contains?(downcased, "cloud") -> :cloud_drafter
      String.contains?(downcased, "critic") -> :critic
      String.contains?(downcased, "review") -> :reviewer
      String.contains?(downcased, "synth") -> :synthesizer
      String.contains?(downcased, "draft") -> :local_drafter
      true -> nil
    end
  end

  defp role_from_agent_name(_name), do: nil

  defp role_from_prompt(prompt) do
    cond do
      String.contains?(prompt, "Create a concise implementation plan") -> :planner
      String.contains?(prompt, "Produce an implementation draft") -> :local_drafter
      String.contains?(prompt, "Review this draft") -> :reviewer
      String.contains?(prompt, "Synthesize the final answer") -> :synthesizer
      true -> :agent
    end
  end

  defp fail_role?(role, opts) do
    opts
    |> Keyword.get(:fail_role)
    |> List.wrap()
    |> Enum.any?(&(normalize_name(&1) == normalize_name(role)))
  end

  defp scripted_response(role, opts) do
    script = Keyword.get(opts, :script)
    agent_name = Keyword.get(opts, :agent_name)

    cond do
      is_map(script) ->
        Map.get(script, role) ||
          Map.get(script, normalize_name(role)) ||
          Map.get(script, agent_name)

      is_list(script) ->
        Keyword.get(script, role) || Keyword.get(script, normalize_name(role))

      true ->
        nil
    end
  end

  defp normalize_scripted_response({:error, reason}), do: {:error, reason}
  defp normalize_scripted_response(%{error: reason}), do: {:error, reason}
  defp normalize_scripted_response(%{"error" => reason}), do: {:error, reason}

  defp normalize_scripted_response(%{} = response) do
    {:ok,
     %{
       content: Map.get(response, :content) || Map.get(response, "content") || "",
       tool_calls: Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
     }}
  end

  defp normalize_scripted_response(content), do: {:ok, to_string(content)}

  defp response_chunks(_response, chunks) when is_list(chunks), do: Enum.map(chunks, &to_string/1)

  defp response_chunks(%{content: content}, _chunks), do: [to_string(content || "")]
  defp response_chunks(content, _chunks), do: [to_string(content)]

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: String.downcase(value)
  defp normalize_name(value), do: to_string(value)

  defp maybe_sleep(opts) do
    case Keyword.get(opts, :delay_ms) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _other -> :ok
    end
  end
end
