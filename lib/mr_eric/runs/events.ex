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
    :tool_completed,
    :tool_failed
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

  defp sanitize_payload(payload, event)
       when event in [:stage_failed, :run_failed, :tool_failed] do
    error = Map.get(payload, :error) || Map.get(payload, :reason) || Map.get(payload, :value)
    Map.put(payload, :error, public_error(error))
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
    |> String.replace(
      ~r/(?i)(api[_-]?key|authorization|bearer|cookie|token|secret)\s*[:=]\s*["']?\S+/,
      "\\1=[REDACTED]"
    )
  end
end
