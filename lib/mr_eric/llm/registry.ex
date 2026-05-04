defmodule MrEric.LLM.Registry do
  @moduledoc """
  Registry for assigning LLM agents to orchestration roles.

  The registry keeps model/provider selection separate from orchestration so
  callers can override role assignments per request or through application
  config.
  """

  @role_keys %{
    planner: :planner,
    draft: :drafts,
    drafts: :drafts,
    reviewer: :reviewers,
    reviewers: :reviewers,
    synthesizer: :synthesizer
  }

  @doc """
  Returns normalized agent specs for a role.

  Pass `:registry` in opts to override the configured registry for a request.
  """
  def agents(role, opts \\ []) do
    role_key = role_key(role)
    role_name = role_name(role_key)
    registry = Keyword.get(opts, :registry) || configured_registry()

    registry
    |> Map.get(role_key, Map.get(default_registry(opts), role_key, []))
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, index} -> normalize_spec(spec, role_name, index, opts) end)
  end

  defp configured_registry do
    Application.get_env(:mr_eric, :llm_registry, %{})
  end

  defp default_registry(opts) do
    provider = Keyword.get(opts, :provider, configured_provider())
    model = Keyword.get(opts, :model, default_model())

    %{
      planner: [%{name: "planner", provider: provider, model: model}],
      drafts: [
        %{name: "draft-primary", provider: provider, model: model},
        %{name: "draft-secondary", provider: provider, model: model}
      ],
      reviewers: [
        %{name: "reviewer-primary", provider: provider, model: model},
        %{name: "reviewer-secondary", provider: provider, model: model}
      ],
      synthesizer: [%{name: "synthesizer", provider: provider, model: model}]
    }
  end

  defp normalize_spec(spec, role, index, opts) when is_list(spec) do
    spec
    |> Map.new()
    |> normalize_spec(role, index, opts)
  end

  defp normalize_spec(spec, role, index, opts) when is_map(spec) do
    spec
    |> Map.put_new(:role, role)
    |> Map.put_new(:name, "#{role}-#{index}")
    |> Map.put_new(:provider, Keyword.get(opts, :provider, configured_provider()))
    |> Map.put_new(:model, Keyword.get(opts, :model, default_model()))
  end

  defp role_key(role), do: Map.fetch!(@role_keys, role)

  defp role_name(:planner), do: :planner
  defp role_name(:drafts), do: :draft
  defp role_name(:reviewers), do: :reviewer
  defp role_name(:synthesizer), do: :synthesizer

  defp configured_provider do
    Application.get_env(:mr_eric, :ai_provider) || System.get_env("AI_PROVIDER") || :openai
  end

  defp default_model do
    Application.get_env(:mr_eric, :openai_model, "gpt-4o")
  end
end
