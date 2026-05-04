defmodule MrEric.Evals do
  @moduledoc """
  Public API for deterministic Phase 9 evals.
  """

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Runner

  @cases_file "phase9_golden_cases.json"

  def list_cases do
    @cases_file
    |> eval_file()
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&EvalCase.from_map/1)
    |> Enum.filter(&EvalCase.enabled?/1)
  end

  def run_case(name, opts \\ [])

  def run_case(name, opts) when is_binary(name) do
    case Enum.find(list_cases(), &(&1.name == name)) do
      nil -> {:error, :unknown_eval_case}
      eval_case -> run_case(eval_case, opts)
    end
  end

  def run_case(%EvalCase{} = eval_case, opts), do: Runner.run_case(eval_case, opts)

  def run_all(opts \\ []) do
    results =
      list_cases()
      |> Enum.map(fn eval_case ->
        case run_case(eval_case, opts) do
          {:ok, result} -> result
          {:error, result} when is_map(result) -> result
          {:error, reason} -> %{case: eval_case.name, status: :failed, reason: reason}
        end
      end)

    passed = Enum.count(results, &(&1.status == :passed))
    failed = length(results) - passed

    {:ok, %{passed: passed, failed: failed, results: results}}
  end

  defp eval_file(filename) do
    case :code.priv_dir(:mr_eric) do
      {:error, _reason} -> Path.join(["priv", "evals", filename])
      priv_dir -> Path.join([to_string(priv_dir), "evals", filename])
    end
  end
end
