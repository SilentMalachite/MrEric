defmodule MrEric.Errors do
  @moduledoc """
  Classifies internal failures and converts them to short, redacted messages.
  """

  @classifications [
    :missing_api_key,
    :provider_unavailable,
    :model_unavailable,
    :timeout,
    :tool_denied,
    :approval_required,
    :approval_rejected,
    :patch_rejected,
    :patch_apply_failed,
    :rag_failed,
    :mcp_unavailable,
    :cancelled,
    :unknown
  ]

  @sensitive_key_pattern ~r/(^|_)(api_?key|authorization|bearer|cookie|password|token|secret)($|_)/

  def classifications, do: @classifications

  def classify(:missing_api_key), do: :missing_api_key
  def classify(:econnrefused), do: :provider_unavailable
  def classify(:provider_unavailable), do: :provider_unavailable
  def classify(:model_unavailable), do: :model_unavailable
  def classify(:timeout), do: :timeout
  def classify(:tool_result_timeout), do: :timeout
  def classify(:tool_denied), do: :tool_denied
  def classify(:unknown_tool), do: :tool_denied
  def classify(:dangerous_command), do: :tool_denied
  def classify(:approval_required), do: :approval_required
  def classify(:approval_rejected), do: :approval_rejected
  def classify(:tool_rejected), do: :approval_rejected
  def classify(:patch_rejected), do: :patch_rejected
  def classify(:before_mismatch), do: :patch_rejected
  def classify(:invalid_patch), do: :patch_rejected
  def classify(:patch_apply_failed), do: :patch_apply_failed
  def classify(:rag_failed), do: :rag_failed
  def classify(:mcp_unavailable), do: :mcp_unavailable
  def classify(:cancelled), do: :cancelled
  def classify(:run_cancelled), do: :cancelled

  def classify(%{status: 401}), do: :missing_api_key
  def classify(%{status: 403}), do: :missing_api_key
  def classify(%{status: 404}), do: :model_unavailable

  def classify(%{status: status}) when is_integer(status) and status >= 500,
    do: :provider_unavailable

  def classify(%{reason: reason}), do: classify(reason)
  def classify(%{error: reason}), do: classify(reason)
  def classify({:error, reason}), do: classify(reason)
  def classify({_kind, reason}), do: classify(reason)

  def classify(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    cond do
      String.contains?(downcased, "missing") and String.contains?(downcased, "api") ->
        :missing_api_key

      String.contains?(downcased, "timeout") ->
        :timeout

      String.contains?(downcased, "model") and String.contains?(downcased, "not found") ->
        :model_unavailable

      String.contains?(downcased, "approval") and String.contains?(downcased, "reject") ->
        :approval_rejected

      String.contains?(downcased, "approval") ->
        :approval_required

      String.contains?(downcased, "mcp") ->
        :mcp_unavailable

      true ->
        :unknown
    end
  end

  def classify(_reason), do: :unknown

  def to_safe_message(reason) do
    safe_reason = redact(reason)

    case classify(reason) do
      :missing_api_key ->
        "The selected provider is missing its API key."

      :provider_unavailable ->
        "The selected provider is unavailable."

      :model_unavailable ->
        "The selected model or endpoint was not found."

      :timeout ->
        "The operation timed out."

      :tool_denied ->
        "Tool request denied."

      :approval_required ->
        "Tool approval is required."

      :approval_rejected ->
        "Tool approval was rejected."

      :patch_rejected ->
        "Patch proposal was rejected by validation."

      :patch_apply_failed ->
        "Patch application failed."

      :rag_failed ->
        "Project context lookup failed, so the run continued without it."

      :mcp_unavailable ->
        "MCP is unavailable or disabled."

      :cancelled ->
        "Run cancelled."

      :unknown ->
        fallback_message(safe_reason)
    end
  end

  def redact(%DateTime{} = value), do: value

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(nested)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value) do
    value
    |> String.replace(~r/sk-[A-Za-z0-9_\-]{8,}/, "[REDACTED]")
    |> String.replace(~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/, "Bearer [REDACTED]")
    |> String.replace(~r/(?i)authorization\s*[:=]\s*Bearer\s+\S+/, "authorization=[REDACTED]")
    |> String.replace(
      ~r/(?i)\b(OPENAI_API_KEY|OPENROUTER_API_KEY|GROK_API_KEY|XAI_API_KEY|LMSTUDIO_API_KEY|OLLAMA_API_KEY)\s*[:=]\s*["']?[^"'\s]+/,
      "\\1=[REDACTED]"
    )
    |> String.replace(
      ~r/(?i)\b(access_token|refresh_token|password|api[_-]?key|secret)\s*[:=]\s*["']?[^"'\s]+/,
      "\\1=[REDACTED]"
    )
    |> String.replace(
      ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
      "[REDACTED PRIVATE KEY]"
    )
  end

  def redact(value), do: value

  defp fallback_message(reason) when is_binary(reason) do
    reason
    |> String.slice(0, 240)
    |> case do
      "" -> "The operation failed."
      message -> message
    end
  end

  defp fallback_message(reason), do: inspect(reason, limit: 20, printable_limit: 240)

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> then(&Regex.match?(@sensitive_key_pattern, &1))
  end
end
