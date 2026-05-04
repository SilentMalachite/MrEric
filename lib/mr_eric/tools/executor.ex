defmodule MrEric.Tools.Executor do
  @moduledoc """
  Executes Phase 5A tools through the registry and policy layer.
  """

  alias MrEric.Tools.Policy
  alias MrEric.Tools.Registry

  def execute(tool, args, opts \\ []) do
    args = Policy.normalize_args(args)

    with {:ok, module} <- Registry.fetch(tool),
         {:ok, decision} <- Policy.authorize(module.name(), args, opts) do
      if decision.approval_required? and not Keyword.get(opts, :approved?, false) do
        {:approval_required, approval_request(module, args, decision, opts)}
      else
        module.run(args, opts)
      end
    end
  end

  def request_tool(tool, args, reason, opts) do
    case execute(tool, args, opts) do
      {:approval_required, request} ->
        {:approval_required, maybe_append_reason(request, reason)}

      result ->
        result
    end
  end

  def execute_approved(request, opts \\ []) when is_map(request) do
    request = Policy.normalize_args(request)

    with :ok <- verify_approval_request(request) do
      tool = Map.fetch!(request, :tool)
      args = Map.fetch!(request, :args)

      execute(tool, args, Keyword.put(opts, :approved?, true))
    end
  end

  defp approval_request(module, args, decision, opts) do
    approval_id = Keyword.get(opts, :approval_id) || new_id("approval")
    tool_call_id = Keyword.get(opts, :tool_call_id) || new_id("tool")

    %{
      approval_id: approval_id,
      approval_token: approval_token(module.name(), args, approval_id, tool_call_id),
      tool_call_id: tool_call_id,
      tool: module.name(),
      args: args,
      reason: Map.get(decision, :reason, "Tool execution requires approval."),
      requested_at: DateTime.utc_now()
    }
  end

  defp maybe_append_reason(request, reason) when is_binary(reason) and reason != "" do
    policy_reason = Map.get(request, :reason)

    reason =
      if is_binary(policy_reason) and policy_reason != reason do
        policy_reason <> " Model reason: " <> reason
      else
        reason
      end

    Map.put(request, :reason, reason)
  end

  defp maybe_append_reason(request, _reason), do: request

  defp verify_approval_request(%{
         tool: tool,
         args: args,
         approval_id: approval_id,
         tool_call_id: tool_call_id,
         approval_token: token
       })
       when is_binary(approval_id) and is_binary(tool_call_id) and is_binary(token) do
    expected = approval_token(tool, args, approval_id, tool_call_id)

    if Plug.Crypto.secure_compare(token, expected) do
      :ok
    else
      {:error, :approval_required}
    end
  end

  defp verify_approval_request(_request), do: {:error, :approval_required}

  defp approval_token(tool, args, approval_id, tool_call_id) do
    data = :erlang.term_to_binary({tool, args, approval_id, tool_call_id})

    :hmac
    |> :crypto.mac(:sha256, approval_secret(), data)
    |> Base.url_encode64(padding: false)
  end

  defp approval_secret do
    key = {__MODULE__, :approval_secret}

    case :persistent_term.get(key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32)
        :persistent_term.put(key, secret)
        secret

      secret ->
        secret
    end
  end

  defp new_id(prefix) do
    prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
