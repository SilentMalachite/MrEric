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

  @registry_role_order [:planner, :drafts, :reviewers, :synthesizer]

  @provider_aliases %{
    "xai" => "grok",
    "llstudio" => "lmstudio"
  }

  @provider_defaults %{
    "openai" => "gpt-4o",
    "grok" => "grok-3",
    "openrouter" => "openrouter/auto",
    "ollama" => "llama3.1",
    "lmstudio" => "local-model"
  }

  @provider_catalog [
    %{
      id: "openai",
      label: "OpenAI",
      models: [
        %{id: "gpt-4o", label: "GPT-4o (Recommended)"},
        %{id: "gpt-4o-mini", label: "GPT-4o Mini"},
        %{id: "gpt-4-turbo", label: "GPT-4 Turbo"},
        %{id: "gpt-4", label: "GPT-4"},
        %{id: "gpt-3.5-turbo", label: "GPT-3.5 Turbo"},
        %{id: "o1-preview", label: "O1 Preview"},
        %{id: "o1-mini", label: "O1 Mini"}
      ]
    },
    %{
      id: "grok",
      label: "Grok / xAI",
      models: [
        %{id: "grok-3", label: "Grok 3"},
        %{id: "grok-3-mini", label: "Grok 3 Mini"}
      ]
    },
    %{
      id: "openrouter",
      label: "OpenRouter",
      models: [
        %{id: "openrouter/auto", label: "Auto"},
        %{id: "openai/gpt-4o", label: "OpenAI GPT-4o"},
        %{id: "openai/gpt-4o-mini", label: "OpenAI GPT-4o Mini"}
      ]
    },
    %{
      id: "ollama",
      label: "Ollama",
      models: [
        %{id: "llama3.1", label: "Llama 3.1"},
        %{id: "llama3", label: "Llama 3"},
        %{id: "qwen2.5-coder", label: "Qwen 2.5 Coder"},
        %{id: "mistral", label: "Mistral"}
      ]
    },
    %{
      id: "lmstudio",
      label: "LM Studio",
      models: [
        %{id: "local-model", label: "Local Model"}
      ]
    }
  ]

  @doc """
  Returns selectable providers for UI surfaces.

  This intentionally exposes only provider identifiers and display labels. API
  keys and endpoint details remain environment/configuration concerns.
  """
  def providers do
    Enum.map(@provider_catalog, &Map.take(&1, [:id, :label]))
  end

  @doc """
  Returns model choices for a provider.

  Models configured in `:llm_registry` are shown first, followed by the
  provider default and the built-in provider catalog.
  """
  def models_for_provider(provider, opts \\ []) do
    provider_id = provider_id(provider)
    registry = Keyword.get(opts, :registry) || configured_registry()

    registry_models =
      registry
      |> registry_specs()
      |> Enum.filter(&(provider_id(Map.get(&1, :provider)) == provider_id))
      |> Enum.map(&model_option(Map.get(&1, :model)))

    provider_models =
      @provider_catalog
      |> Enum.find(%{models: []}, &(&1.id == provider_id))
      |> Map.fetch!(:models)

    (registry_models ++ [model_option(default_model(provider_id))] ++ provider_models)
    |> Enum.reject(&is_nil(&1.id))
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Returns the default provider id used by the UI and default registry.
  """
  def default_provider do
    configured_provider()
    |> provider_id()
  end

  @doc """
  Returns the default model for the selected provider.
  """
  def default_model(provider \\ nil) do
    provider_id = provider_id(provider || configured_provider())

    case provider_id do
      "openai" -> Application.get_env(:mr_eric, :openai_model, @provider_defaults["openai"])
      _ -> Map.fetch!(@provider_defaults, provider_id)
    end
  end

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
    provider =
      opts
      |> Keyword.get(:provider, configured_provider())
      |> provider_id()

    model = Keyword.get(opts, :model, default_model(provider))

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
    provider = Map.get(spec, :provider) || Keyword.get(opts, :provider, default_provider())
    model = Keyword.get(opts, :model) || Map.get(spec, :model) || default_model(provider)

    spec
    |> Map.put_new(:role, role)
    |> Map.put_new(:name, "#{role}-#{index}")
    |> Map.put_new(:provider, provider)
    |> Map.put_new(:model, model)
  end

  defp role_key(role), do: Map.fetch!(@role_keys, role)

  defp role_name(:planner), do: :planner
  defp role_name(:drafts), do: :draft
  defp role_name(:reviewers), do: :reviewer
  defp role_name(:synthesizer), do: :synthesizer

  defp configured_provider do
    Application.get_env(:mr_eric, :ai_provider) || System.get_env("AI_PROVIDER") || :openai
  end

  defp provider_id(provider) when provider in [nil, ""], do: default_provider()

  defp provider_id(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> provider_id()
  end

  defp provider_id(provider) when is_binary(provider) do
    provider_id =
      provider
      |> String.downcase()
      |> then(&Map.get(@provider_aliases, &1, &1))

    if Enum.any?(@provider_catalog, &(&1.id == provider_id)) do
      provider_id
    else
      "openai"
    end
  end

  defp registry_specs(registry) when is_map(registry) do
    ordered_specs =
      @registry_role_order
      |> Enum.flat_map(&(registry |> Map.get(&1, []) |> List.wrap()))

    extra_specs =
      registry
      |> Map.drop(@registry_role_order)
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)

    (ordered_specs ++ extra_specs)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&spec_to_map/1)
  end

  defp registry_specs(_registry), do: []

  defp spec_to_map(spec) when is_list(spec), do: Map.new(spec)
  defp spec_to_map(spec) when is_map(spec), do: spec
  defp spec_to_map(_spec), do: %{}

  defp model_option(nil), do: %{id: nil, label: nil}

  defp model_option(model) do
    id = to_string(model)
    %{id: id, label: id}
  end
end
