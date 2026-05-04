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

  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: string_field(map, "name"),
      task: string_field(map, "task"),
      scenario: string_field(map, "scenario"),
      approval_action: approval_action(Map.get(map, "approval_action")),
      cancel_after_ms: Map.get(map, "cancel_after_ms"),
      fail_role: Map.get(map, "fail_role"),
      requires: list_field(map, "requires"),
      expected_status: status(Map.get(map, "expected_status")),
      expected_final_contains: list_field(map, "expected_final_contains"),
      expected_events: events(Map.get(map, "expected_events")),
      forbidden_events: events(Map.get(map, "forbidden_events")),
      expected_no_secret_leak: Map.get(map, "expected_no_secret_leak", true),
      expected_approval_required: Map.get(map, "expected_approval_required", false),
      expected_tool_denied: Map.get(map, "expected_tool_denied", false),
      expected_tool_rejected: Map.get(map, "expected_tool_rejected", false),
      expected_patch_applied: Map.get(map, "expected_patch_applied"),
      expected_error_classification: classification(Map.get(map, "expected_error_classification"))
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

  defp requirement_available?(_requirement), do: false

  defp string_field(map, field), do: Map.get(map, field) || ""

  defp list_field(map, field) do
    case Map.get(map, field, []) do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _other -> []
    end
  end

  defp status(value) when is_binary(value), do: Map.get(@statuses, value, :completed)
  defp status(value) when is_atom(value), do: value
  defp status(_value), do: :completed

  defp events(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_atom(value) -> value
      value when is_binary(value) -> Map.get(@events, value)
      _value -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp events(_values), do: []

  defp approval_action(value) when is_binary(value), do: Map.get(@approval_actions, value)
  defp approval_action(value) when is_atom(value), do: value
  defp approval_action(_value), do: nil

  defp classification(value) when is_binary(value), do: Map.get(@classifications, value)
  defp classification(value) when is_atom(value), do: value
  defp classification(_value), do: nil
end
