defmodule MrEric.Evals.Case do
  @moduledoc """
  A deterministic golden evaluation case.
  """

  defstruct [
    :name,
    :task,
    :scenario,
    :approval_action,
    :cancel_after_ms,
    :fail_role,
    :requires,
    expected_status: :completed,
    expected_final_contains: [],
    expected_events: [],
    forbidden_events: [],
    expected_no_secret_leak: true,
    expected_approval_required: false,
    expected_tool_denied: false,
    expected_tool_rejected: false,
    expected_patch_applied: nil,
    expected_error_classification: nil
  ]

  @statuses %{
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "running" => :running,
    "waiting_for_approval" => :waiting_for_approval
  }

  @events %{
    "run_started" => :run_started,
    "stage_started" => :stage_started,
    "stage_chunk" => :stage_chunk,
    "stage_completed" => :stage_completed,
    "stage_failed" => :stage_failed,
    "run_completed" => :run_completed,
    "run_failed" => :run_failed,
    "run_cancelled" => :run_cancelled,
    "tool_started" => :tool_started,
    "tool_approval_requested" => :tool_approval_requested,
    "tool_approval_resolved" => :tool_approval_resolved,
    "tool_completed" => :tool_completed,
    "tool_failed" => :tool_failed,
    "tool_denied" => :tool_denied,
    "tool_rejected" => :tool_rejected
  }

  @approval_actions %{
    "approve" => :approve,
    "reject" => :reject,
    "deny" => :reject,
    "none" => :none
  }

  @classifications %{
    "missing_api_key" => :missing_api_key,
    "provider_unavailable" => :provider_unavailable,
    "model_unavailable" => :model_unavailable,
    "timeout" => :timeout,
    "tool_denied" => :tool_denied,
    "approval_required" => :approval_required,
    "approval_rejected" => :approval_rejected,
    "patch_rejected" => :patch_rejected,
    "patch_apply_failed" => :patch_apply_failed,
    "rag_failed" => :rag_failed,
    "mcp_unavailable" => :mcp_unavailable,
    "cancelled" => :cancelled,
    "unknown" => :unknown
  }

  @requirements ~w(rag mcp)

  @doc """
  Builds a case from its JSON map, raising on any value it cannot recognize.

  Golden cases are fixtures in this repository, not user input. An *absent*
  optional field means "this case does not assert that", which is legal; a
  *present but unrecognized* one means the fixture is wrong. Lenient parsing
  used to turn the second into the first -- an unknown event name was dropped
  from the list, an unknown classification became `nil`, which is the value
  that switches `Scorer.assert_error_classification/3` off -- so a typo made
  the suite assert less and still report green.
  """
  def from_map!(map) when is_map(map) do
    name = string_field(map, "name")

    %__MODULE__{
      name: name,
      task: string_field(map, "task"),
      scenario: string_field(map, "scenario"),
      approval_action: approval_action!(name, Map.get(map, "approval_action")),
      cancel_after_ms: Map.get(map, "cancel_after_ms"),
      fail_role: Map.get(map, "fail_role"),
      requires: requires!(name, Map.get(map, "requires")),
      expected_status: status!(name, Map.get(map, "expected_status")),
      expected_final_contains: list_field(map, "expected_final_contains"),
      expected_events: events!(name, "expected_events", Map.get(map, "expected_events")),
      forbidden_events: events!(name, "forbidden_events", Map.get(map, "forbidden_events")),
      expected_no_secret_leak: Map.get(map, "expected_no_secret_leak", true),
      expected_approval_required: Map.get(map, "expected_approval_required", false),
      expected_tool_denied: Map.get(map, "expected_tool_denied", false),
      expected_tool_rejected: Map.get(map, "expected_tool_rejected", false),
      expected_patch_applied: Map.get(map, "expected_patch_applied"),
      expected_error_classification:
        classification!(name, Map.get(map, "expected_error_classification"))
    }
  end

  def enabled?(%__MODULE__{requires: requires}) do
    Enum.all?(requires, &requirement_available?/1)
  end

  defp requirement_available?("rag") do
    Code.ensure_loaded?(MrEric.RAG) and function_exported?(MrEric.RAG, :context_for, 2)
  end

  defp requirement_available?("mcp") do
    (Code.ensure_loaded?(MrEric.MCP.ClientBehaviour) and
       function_exported?(MrEric.MCP.ClientBehaviour, :module_info, 0)) or
      (Code.ensure_loaded?(MrEric.MCP.ToolAdapter) and
         function_exported?(MrEric.MCP.ToolAdapter, :module_info, 0))
  end

  defp string_field(map, field), do: Map.get(map, field) || ""

  defp list_field(map, field) do
    case Map.get(map, field, []) do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _other -> []
    end
  end

  defp status!(_name, nil), do: :completed
  defp status!(_name, value) when is_atom(value), do: value

  defp status!(name, value) when is_binary(value) do
    case Map.fetch(@statuses, value) do
      {:ok, status} -> status
      :error -> bad!(name, "expected_status", value, Map.keys(@statuses))
    end
  end

  defp status!(name, value), do: bad!(name, "expected_status", value, Map.keys(@statuses))

  defp events!(_name, _field, nil), do: []

  defp events!(name, field, values) when is_list(values) do
    Enum.map(values, fn
      value when is_atom(value) ->
        value

      value when is_binary(value) ->
        case Map.fetch(@events, value) do
          {:ok, event} -> event
          :error -> bad!(name, field, value, Map.keys(@events))
        end

      value ->
        bad!(name, field, value, Map.keys(@events))
    end)
  end

  defp events!(name, field, value), do: bad!(name, field, value, Map.keys(@events))

  defp approval_action!(_name, nil), do: nil
  defp approval_action!(_name, value) when is_atom(value), do: value

  defp approval_action!(name, value) when is_binary(value) do
    case Map.fetch(@approval_actions, value) do
      {:ok, action} -> action
      :error -> bad!(name, "approval_action", value, Map.keys(@approval_actions))
    end
  end

  defp approval_action!(name, value),
    do: bad!(name, "approval_action", value, Map.keys(@approval_actions))

  defp classification!(_name, nil), do: nil
  defp classification!(_name, value) when is_atom(value), do: value

  defp classification!(name, value) when is_binary(value) do
    case Map.fetch(@classifications, value) do
      {:ok, classification} -> classification
      :error -> bad!(name, "expected_error_classification", value, Map.keys(@classifications))
    end
  end

  defp classification!(name, value),
    do: bad!(name, "expected_error_classification", value, Map.keys(@classifications))

  defp requires!(_name, nil), do: []

  defp requires!(name, values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) and value in @requirements -> value
      value -> bad!(name, "requires", value, @requirements)
    end)
  end

  defp requires!(name, value) when is_binary(value), do: requires!(name, [value])
  defp requires!(name, value), do: bad!(name, "requires", value, @requirements)

  defp bad!(case_name, field, value, allowed) do
    raise ArgumentError,
          "golden eval case #{inspect(case_name)}: unrecognized #{field} #{inspect(value)}. " <>
            "Allowed: #{Enum.map_join(Enum.sort(allowed), ", ", &inspect/1)}"
  end
end
