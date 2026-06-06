defmodule MrEric.LLM.ProviderResolverTest do
  use ExUnit.Case, async: false

  alias MrEric.LLM.ProviderResolver

  @chain [:lmstudio, :ollama, :openai]

  setup do
    previous = Application.get_env(:mr_eric, :resolved_default_provider)
    Application.delete_env(:mr_eric, :resolved_default_provider)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mr_eric, :resolved_default_provider)
      else
        Application.put_env(:mr_eric, :resolved_default_provider, previous)
      end
    end)

    :ok
  end

  describe "resolve/2" do
    test "returns the first provider in the chain when it is healthy" do
      assert ProviderResolver.resolve(@chain, health_check: fn _ -> true end) == :lmstudio
    end

    test "falls through to the next provider when an earlier one is unreachable" do
      health = fn
        :lmstudio -> false
        _ -> true
      end

      assert ProviderResolver.resolve(@chain, health_check: health) == :ollama
    end

    test "returns the terminal provider without probing it when all others are unreachable" do
      test_pid = self()

      health = fn provider ->
        send(test_pid, {:probed, provider})
        false
      end

      assert ProviderResolver.resolve(@chain, health_check: health) == :openai

      assert_received {:probed, :lmstudio}
      assert_received {:probed, :ollama}
      refute_received {:probed, :openai}
    end

    test "honors a custom chain" do
      assert ProviderResolver.resolve([:ollama, :openai], health_check: fn _ -> true end) == :ollama
    end
  end

  describe "resolve_and_cache/1" do
    test "skips health checks and returns the static fallback when disabled" do
      test_pid = self()

      health = fn provider ->
        send(test_pid, {:probed, provider})
        true
      end

      assert ProviderResolver.resolve_and_cache(enabled: false, health_check: health) == :openai
      refute_received {:probed, _provider}
      assert ProviderResolver.default_provider() == :openai
    end

    test "caches the resolved provider so default_provider/0 returns it" do
      assert ProviderResolver.resolve_and_cache(
               enabled: true,
               chain: [:ollama, :openai],
               health_check: fn _ -> true end
             ) == :ollama

      assert ProviderResolver.default_provider() == :ollama
    end
  end

  describe "default_provider/0" do
    test "returns :openai when nothing has been cached" do
      assert ProviderResolver.default_provider() == :openai
    end
  end

  describe "explicit_provider_configured?/0" do
    test "is true when application config sets a provider" do
      previous = Application.get_env(:mr_eric, :ai_provider)
      Application.put_env(:mr_eric, :ai_provider, :grok)
      on_exit(fn -> restore_env(:ai_provider, previous) end)

      assert ProviderResolver.explicit_provider_configured?()
    end

    test "is false when neither config nor AI_PROVIDER env is set" do
      previous = Application.get_env(:mr_eric, :ai_provider)
      Application.delete_env(:mr_eric, :ai_provider)
      on_exit(fn -> restore_env(:ai_provider, previous) end)

      if System.get_env("AI_PROVIDER") do
        # The host shell exported AI_PROVIDER; the predicate must reflect that.
        assert ProviderResolver.explicit_provider_configured?()
      else
        refute ProviderResolver.explicit_provider_configured?()
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mr_eric, key)
  defp restore_env(key, value), do: Application.put_env(:mr_eric, key, value)
end
