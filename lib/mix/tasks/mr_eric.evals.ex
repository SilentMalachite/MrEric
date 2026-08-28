defmodule Mix.Tasks.MrEric.Evals do
  @moduledoc """
  Runs deterministic MrEric evals with the fake LLM provider.
  """

  use Mix.Task

  @shortdoc "Runs MrEric deterministic evals"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [case: :string],
        aliases: [c: :case]
      )

    result =
      case Keyword.get(opts, :case) do
        nil -> MrEric.Evals.run_all()
        name -> run_single(name)
      end

    print_result(result)
  end

  defp run_single(name) do
    case MrEric.Evals.run_case(name) do
      {:ok, result} ->
        {:ok, %{passed: 1, failed: 0, skipped: [], results: [result]}}

      {:error, {:case_disabled, requires}} ->
        {:ok, %{passed: 0, failed: 0, skipped: [%{case: name, requires: requires}], results: []}}

      {:error, result} when is_map(result) ->
        {:ok, %{passed: 0, failed: 1, skipped: [], results: [result]}}

      {:error, reason} ->
        {:ok,
         %{
           passed: 0,
           failed: 1,
           skipped: [],
           results: [%{case: name, status: :failed, reason: reason}]
         }}
    end
  end

  defp print_result({:ok, summary}) do
    Enum.each(summary.results, fn result ->
      Mix.shell().info("#{result.case}: #{result.status}")
    end)

    Enum.each(summary.skipped, fn skipped ->
      Mix.shell().info(
        "#{skipped.case}: skipped (requires: #{Enum.join(skipped.requires, ", ")})"
      )
    end)

    Mix.shell().info(
      "passed=#{summary.passed} failed=#{summary.failed} skipped=#{length(summary.skipped)}"
    )

    # A skip is a legitimate machine configuration, not a failure. It is only
    # forbidden from being invisible.
    if summary.failed > 0 do
      Mix.raise("MrEric evals failed")
    end
  end
end
