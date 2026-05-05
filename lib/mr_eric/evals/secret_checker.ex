defmodule MrEric.Evals.SecretChecker do
  @moduledoc """
  Detects likely secret leaks in eval output without echoing secret values.

  Two detection strategies, applied together:

    1. **Sensitive-key alert.** When a map key matches the sensitive-name
       regex, the *value* must be empty, nil, or one of a small set of
       placeholders (e.g. `"[REDACTED]"`). A non-empty, non-redacted value
       under such a key is reported as `:sensitive_key_unredacted`.

    2. **Pattern match.** Every binary in the input is scanned for known
       secret shapes (`sk-…`, Bearer tokens, env-style assignments, PEM
       private keys, …) and reported as `:pattern_match`.

  The walk is recursive over maps, lists, tuples, and (most) structs, with
  a small denylist of metadata-only keys that are never scanned. This is
  deliberate: any new field added to a Run trace is scanned by default.
  """

  alias MrEric.Evals.SecretChecker.Result

  @sensitive_key_regex ~r/(^|_)(api_?key|authorization|bearer|cookie|password|passwd|secret|token|credential|session)($|_)/

  @placeholder_values ~w([REDACTED] <REDACTED> <redacted> [redacted] *** REDACTED redacted)

  @ignored_keys ~w(status duration_ms case_id stage_durations indexed_at file_count)a

  @patterns [
    {:named_api_key,
     ~r/\b(OPENAI_API_KEY|OPENROUTER_API_KEY|GROK_API_KEY|XAI_API_KEY|LMSTUDIO_API_KEY|OLLAMA_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY)\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i},
    {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/i},
    {:openai_key, ~r/\bsk-[A-Za-z0-9_\-]{8,}/},
    {:env_content, ~r/^\s*[A-Z][A-Z0-9_]{3,}\s*=\s*(?!\[REDACTED\])\S+/m},
    {:private_key, ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/},
    {:access_token, ~r/\baccess_token\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i},
    {:refresh_token, ~r/\brefresh_token\s*[:=]\s*["']?(?!\[REDACTED\])[^"'\s]+/i}
  ]

  defmodule Result do
    @moduledoc false
    @type finding :: %{
            path: [atom() | binary() | non_neg_integer()],
            reason: :sensitive_key_unredacted | :pattern_match,
            snippet: binary(),
            type: atom() | nil
          }

    defstruct status: :clean, findings: []

    @type t :: %__MODULE__{status: :clean | :leak, findings: [finding()]}
  end

  @spec scan(term()) :: Result.t()
  def scan(value) do
    findings = walk(value, [], [])

    case findings do
      [] -> %Result{status: :clean, findings: []}
      list -> %Result{status: :leak, findings: Enum.reverse(list)}
    end
  end

  @doc """
  Backward-compatible wrapper. Returns `:ok` on a clean scan or
  `{:error, leaks}` where each leak has the legacy `%{type, location}` shape.
  """
  @spec check(term()) :: :ok | {:error, [%{type: atom(), location: binary()}]}
  def check(value) do
    case scan(value) do
      %Result{status: :clean} ->
        :ok

      %Result{findings: findings} ->
        leaks =
          findings
          |> Enum.map(fn f ->
            %{type: f.type || f.reason, location: format_path(f.path)}
          end)
          |> Enum.uniq()

        {:error, leaks}
    end
  end

  @spec leak?(term()) :: boolean()
  def leak?(value), do: match?({:error, _}, check(value))

  # --- Walk ---

  defp walk(value, path, findings) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, findings, fn {k, v}, acc ->
      cond do
        ignored_key?(k) ->
          acc

        sensitive_key?(k) ->
          acc
          |> sensitive_value_check(k, v, path ++ [normalize_key(k)])
          |> then(&walk(v, path ++ [normalize_key(k)], &1))

        true ->
          walk(v, path ++ [normalize_key(k)], acc)
      end
    end)
  end

  defp walk(%DateTime{}, _path, findings), do: findings
  defp walk(%Date{}, _path, findings), do: findings
  defp walk(%NaiveDateTime{}, _path, findings), do: findings
  defp walk(%Time{}, _path, findings), do: findings

  defp walk(%_struct{} = value, path, findings) do
    walk(Map.from_struct(value), path, findings)
  end

  defp walk(value, path, findings) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(findings, fn {v, i}, acc -> walk(v, path ++ [i], acc) end)
  end

  defp walk(value, path, findings) when is_tuple(value) do
    walk(Tuple.to_list(value), path, findings)
  end

  defp walk(value, path, findings) when is_binary(value) do
    case Enum.find(@patterns, fn {_type, regex} -> Regex.match?(regex, value) end) do
      nil ->
        findings

      {type, regex} ->
        [
          %{
            path: path,
            reason: :pattern_match,
            type: type,
            snippet: redact_snippet(value, regex)
          }
          | findings
        ]
    end
  end

  defp walk(_value, _path, findings), do: findings

  # --- Sensitive key handling ---

  defp ignored_key?(k) do
    case k do
      atom when is_atom(atom) -> atom in @ignored_keys
      binary when is_binary(binary) -> String.to_atom(binary) in @ignored_keys
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp sensitive_key?(k) do
    k
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> then(&Regex.match?(@sensitive_key_regex, &1))
  end

  defp normalize_key(k) when is_atom(k) or is_binary(k) or is_integer(k), do: k
  defp normalize_key(k), do: inspect(k)

  defp sensitive_value_check(findings, _key, value, _path) when value in [nil, ""] do
    findings
  end

  defp sensitive_value_check(findings, _key, value, path) when is_binary(value) do
    if value in @placeholder_values or String.match?(value, ~r/^\[REDACTED\]$/i) do
      findings
    else
      [
        %{
          path: path,
          reason: :sensitive_key_unredacted,
          type: :sensitive_key_unredacted,
          snippet: redact_value(value)
        }
        | findings
      ]
    end
  end

  defp sensitive_value_check(findings, _key, _value, path) do
    [
      %{
        path: path,
        reason: :sensitive_key_unredacted,
        type: :sensitive_key_unredacted,
        snippet: "<non-binary value>"
      }
      | findings
    ]
  end

  # --- Snippets ---

  defp redact_value(value) when is_binary(value) do
    head = String.slice(value, 0, 4)
    "#{head}…[REDACTED, len=#{byte_size(value)}]"
  end

  defp redact_snippet(text, regex) do
    case Regex.run(regex, text, return: :index) do
      [{start, len} | _] ->
        prefix_start = max(start - 16, 0)
        prefix = binary_part(text, prefix_start, start - prefix_start)
        suffix_start = start + len
        suffix_len = min(byte_size(text) - suffix_start, 16)
        suffix = if suffix_len > 0, do: binary_part(text, suffix_start, suffix_len), else: ""
        "...#{prefix}[REDACTED]#{suffix}..."

      _ ->
        "[REDACTED]"
    end
  end

  defp format_path([]), do: "(root)"
  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)
end
