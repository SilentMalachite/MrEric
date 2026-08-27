defmodule MrEric.Runs.Events do
  @moduledoc """
  PubSub event helpers for Phase 4 run progress.
  """

  @event_names [
    :run_started,
    :stage_started,
    :stage_chunk,
    :stage_completed,
    :stage_failed,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :tool_started,
    :tool_approval_requested,
    :tool_approval_resolved,
    :tool_approval_expired,
    :tool_completed,
    :tool_failed,
    :tool_denied,
    :tool_rejected,
    # RAG failure never fails a run -- the planner proceeds with empty context
    # -- but it used to say nothing at all, so "RAG broke" and "RAG found
    # nothing" were the same observation.
    :rag_failed
  ]

  def names, do: @event_names

  def topic(run_id), do: "runs:#{run_id}"

  def subscribe(run_id) when not is_nil(run_id) do
    Phoenix.PubSub.subscribe(MrEric.PubSub, topic(run_id))
  end

  def unsubscribe(run_id) when not is_nil(run_id) do
    Phoenix.PubSub.unsubscribe(MrEric.PubSub, topic(run_id))
  end

  def broadcast(run_id, event) when not is_nil(run_id) do
    normalized = normalize_event(run_id, event)
    Phoenix.PubSub.broadcast(MrEric.PubSub, topic(run_id), normalized)
  end

  def normalize_event(run_id, {event, payload}) when event in @event_names do
    payload =
      payload
      |> normalize_payload()
      |> Map.put_new(:run_id, run_id)
      |> sanitize_payload(event)
      |> redact_payload()

    {event, payload}
  end

  def normalize_event(run_id, event) when event in @event_names do
    normalize_event(run_id, {event, %{}})
  end

  def public_error(:missing_api_key), do: "The selected provider is missing its API key."

  def public_error(:econnrefused),
    do:
      "The selected LLM provider is unavailable. Start the local server or choose another provider."

  def public_error(:timeout),
    do: "The selected model timed out. Try again or choose a faster model."

  def public_error(:tool_denied), do: "Tool request denied."
  def public_error(:tool_rejected), do: "Tool request rejected."
  def public_error(:unknown_tool), do: "Tool request denied."
  def public_error(:mcp_unavailable), do: "MCP is unavailable or disabled."
  def public_error(:rag_failed), do: "Project context lookup failed."

  # The cap counts supervised workers, and a finished run keeps its worker for
  # `terminal_run_ttl_ms` after it ends. So the blocking runs may all have
  # finished already, and "wait for one to finish" would be advice that cannot
  # work. Point at the wait that does.
  def public_error(:too_many_runs),
    do: "Too many recent runs. Wait about a minute for a slot to free up, then try again."

  def public_error(:run_lifetime_exceeded),
    do: "The run exceeded its maximum lifetime and was stopped."

  def public_error(%{reason: reason}), do: public_error(reason)

  def public_error(%{status: 401}),
    do: "The selected provider rejected the credentials. Check the configured API key."

  def public_error(%{status: 404}),
    do: "The selected model or endpoint was not found. Check the model name and provider."

  def public_error(%{status: status}) when is_integer(status),
    do: "The selected provider returned HTTP #{status}. Check provider status and configuration."

  def public_error({:fake_failure, name}), do: "Model call failed for #{name}."
  def public_error({:error, reason}), do: public_error(reason)
  def public_error({_kind, reason}), do: public_error(reason)

  def public_error(reason) when is_binary(reason) do
    reason
    |> redact_secrets()
    |> String.slice(0, 240)
  end

  def public_error(_reason) do
    "The model request failed. Check provider configuration, model availability, and local server status."
  end

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(payload), do: %{value: payload}

  # This is the last point at which the raw reason still exists: `:error`
  # leaves here as a sentence written for a human, and recovering a
  # classification from that sentence downstream is keyword-matching against
  # English -- `:run_lifetime_exceeded` becomes "The run exceeded its maximum
  # lifetime and was stopped.", which contains no keyword any classifier looks
  # for, so it classified as `:unknown`. `MrEric.Errors.classify/1` knows the
  # atom exactly, so the classification is taken here and carried alongside.
  # `:error_class` is safe to broadcast: `classify/1` only ever returns a
  # member of the closed `MrEric.Errors.classifications/0` list.
  defp sanitize_payload(payload, event)
       when event in [
              :stage_failed,
              :run_failed,
              :tool_failed,
              :tool_denied,
              :tool_rejected,
              :rag_failed
            ] do
    error = Map.get(payload, :error) || Map.get(payload, :reason) || Map.get(payload, :value)

    payload
    |> Map.put(:error, public_error(error))
    |> Map.put(:error_class, MrEric.Errors.classify(error))
  end

  defp sanitize_payload(payload, _event), do: payload

  defp redact_payload(%DateTime{} = value), do: value

  defp redact_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_payload(value)}
      end
    end)
  end

  defp redact_payload(payload) when is_list(payload), do: Enum.map(payload, &redact_payload/1)

  defp redact_payload(payload) when is_binary(payload), do: redact_secrets(payload)

  defp redact_payload(payload), do: payload

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> then(&Regex.match?(~r/(^|_)(api_?key|authorization|bearer|cookie|token|secret)($|_)/, &1))
  end

  defp redact_secrets(text) do
    text
    |> String.replace(~r/sk-[A-Za-z0-9_\-]+/, "[REDACTED]")
    |> String.replace(~r/(?i)authorization\s*[:=]\s*(bearer\s+)?\S+/, "authorization=[REDACTED]")
    |> String.replace(~r/(?i)bearer\s+\S+/, "bearer [REDACTED]")
    |> String.replace(
      ~r/(?i)(api[_-]?key|authorization|bearer|cookie|token|secret)\s*[:=]\s*["']?\S+/,
      "\\1=[REDACTED]"
    )
  end
end
