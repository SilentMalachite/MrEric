defmodule MrEric.Evals.SecretChecker do
  @moduledoc """
  Detects likely secret leaks in eval output without returning secret values.
  """

  @patterns [
    {:named_api_key,
     ~r/\b(OPENAI_API_KEY|OPENROUTER_API_KEY|GROK_API_KEY|XAI_API_KEY|LMSTUDIO_API_KEY|OLLAMA_API_KEY)\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i},
    {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i},
    {:openai_key, ~r/\bsk-[A-Za-z0-9_\-]{8,}/},
    {:env_content, ~r/^\s*[A-Z][A-Z0-9_]{3,}\s*=\s*(?!\[REDACTED\])\S+/m},
    {:private_key, ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/},
    {:access_token, ~r/\baccess_token\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i},
    {:refresh_token, ~r/\brefresh_token\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i},
    {:password, ~r/\bpassword\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i}
  ]

  def check(value) do
    leaks =
      value
      |> flatten_text()
      |> Enum.with_index()
      |> Enum.flat_map(fn {text, index} -> leaks_for(text, index) end)
      |> Enum.uniq()

    case leaks do
      [] -> :ok
      leaks -> {:error, leaks}
    end
  end

  def leak?(value), do: match?({:error, _leaks}, check(value))

  defp leaks_for(text, index) do
    @patterns
    |> Enum.filter(fn {_type, pattern} -> Regex.match?(pattern, text) end)
    |> Enum.map(fn {type, _pattern} -> %{type: type, location: "text[#{index}]"} end)
  end

  defp flatten_text(value) when is_binary(value), do: [value]

  defp flatten_text(%DateTime{}), do: []

  defp flatten_text(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> flatten_text()
  end

  defp flatten_text(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.flat_map(fn {key, nested} ->
      [to_string(key) | flatten_text(nested)]
    end)
  end

  defp flatten_text(value) when is_list(value), do: Enum.flat_map(value, &flatten_text/1)

  defp flatten_text(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.flat_map(&flatten_text/1)
  end

  defp flatten_text(_value), do: []

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> then(
      &Regex.match?(
        ~r/(^|_)(api_?key|authorization|bearer|cookie|password|token|secret)($|_)/,
        &1
      )
    )
  end
end
