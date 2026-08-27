defmodule MrEric.Evals do
  @moduledoc """
  Public API for deterministic Phase 9 evals.
  """

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Runner

  @cases_file "phase9_golden_cases.json"

  @doc """
  Every golden case in the fixture, runnable here or not.

  This deliberately does **not** filter by `enabled?/1`. Filtering before
  counting is what let `run_all/1` report `passed=13 failed=0` after a case
  quietly left the suite.
  """
  def list_cases do
    @cases_file
    |> eval_file()
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&EvalCase.from_map!/1)
  end

  @doc "Splits the golden cases into `{runnable_here, skipped}`."
  def partition_cases do
    Enum.split_with(list_cases(), &EvalCase.enabled?/1)
  end

  def run_case(name, opts \\ [])

  def run_case(name, opts) when is_binary(name) do
    case Enum.find(list_cases(), &(&1.name == name)) do
      nil ->
        {:error, :unknown_eval_case}

      eval_case ->
        if EvalCase.enabled?(eval_case) do
          run_case(eval_case, opts)
        else
          {:error, {:case_disabled, eval_case.requires}}
        end
    end
  end

  def run_case(%EvalCase{} = eval_case, opts), do: Runner.run_case(eval_case, opts)

  def run_all(opts \\ []) do
    {enabled, skipped} = partition_cases()

    results =
      Enum.map(enabled, fn eval_case ->
        case run_case(eval_case, opts) do
          {:ok, result} -> result
          {:error, result} when is_map(result) -> result
          {:error, reason} -> %{case: eval_case.name, status: :failed, reason: reason}
        end
      end)

    # Counted, not subtracted: deriving `failed` as `length(results) - passed`
    # silently files any future third status under "failed".
    passed = Enum.count(results, &(&1.status == :passed))
    failed = Enum.count(results, &(&1.status != :passed))

    {:ok,
     %{
       passed: passed,
       failed: failed,
       skipped: Enum.map(skipped, &%{case: &1.name, requires: &1.requires}),
       results: results
     }}
  end

  defp eval_file(filename) do
    case :code.priv_dir(:mr_eric) do
      {:error, _reason} -> Path.join(["priv", "evals", filename])
      priv_dir -> Path.join([to_string(priv_dir), "evals", filename])
    end
  end
end
