defmodule MrEric.ConfigHygieneTest do
  use ExUnit.Case, async: true

  @doc_link "docs/superpowers/specs/2026-05-05-secret-hygiene-design.md"

  for path <- ["config/dev.exs", "config/test.exs"] do
    @path path
    test "#{@path} contains no literal secret_key_base assignment" do
      contents = File.read!(@path)

      refute Regex.match?(~r/^[^#\n]*\bsecret_key_base\s*:\s*"/m, contents),
             "Found a literal `secret_key_base: \"...\"` in #{@path}. " <>
               "Hardcoded keys MUST live in config/runtime.exs only. See #{@doc_link}."
    end
  end
end
