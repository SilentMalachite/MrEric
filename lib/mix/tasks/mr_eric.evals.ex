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
        {:ok, %{passed: 1, failed: 0, results: [result]}}

      {:error, result} when is_map(result) ->
        {:ok, %{passed: 0, failed: 1, results: [result]}}

      {:error, reason} ->
        {:ok, %{passed: 0, failed: 1, results: [%{case: name, status: :failed, reason: reason}]}}
    end
  end

  defp print_result({:ok, summary}) do
    Enum.each(summary.results, fn result ->
      Mix.shell().info("#{result.case}: #{result.status}")
    end)

    Mix.shell().info("passed=#{summary.passed} failed=#{summary.failed}")

    if summary.failed > 0 do
      Mix.raise("MrEric evals failed")
    end
  end
end
