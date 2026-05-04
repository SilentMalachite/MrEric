defmodule MrEric.Orchestrator do
  @moduledoc """
  Coordinates Planner, Draft Agents, Reviewers, and Synthesizer.
  """

  alias MrEric.LLM.{Registry, Router}

  @doc """
  Runs a task through the collaborative LLM flow.

  Draft and review stages are parallelized with `Task.async_stream/3`. Failures
  from individual draft/review agents are collected and do not stop the whole
  run when at least one useful draft remains.
  """
  def run(task, opts \\ [])

  def run(task, opts) when is_binary(task) and task != "" do
    with {:ok, planner} <- run_planner(task, opts),
         {:ok, draft_result} <- run_drafts(task, planner.content, opts) do
      review_result = run_reviews(task, planner.content, draft_result.successes, opts)

      synthesis =
        run_synthesizer(
          task,
          planner.content,
          draft_result.successes,
          review_result.successes,
          opts
        )

      {:ok,
       %{
         task: task,
         plan: planner.content,
         planner: planner,
         drafts: draft_result.successes,
         draft_errors: draft_result.errors,
         reviews: review_result.successes,
         review_errors: review_result.errors,
         final: synthesis.final,
         synthesizer: Map.get(synthesis, :synthesizer),
         synthesis_error: Map.get(synthesis, :error)
       }}
    end
  end

  def run(_task, _opts), do: {:error, :invalid_task}

  defp run_planner(task, opts) do
    :planner
    |> Registry.agents(opts)
    |> List.first()
    |> case do
      nil ->
        {:error, %{stage: :planner, reason: :no_agent}}

      planner ->
        Router.complete(planner_prompt(task), planner, opts)
    end
  end

  defp run_drafts(task, plan, opts) do
    agents = Registry.agents(:draft, opts)

    {successes, errors} =
      run_parallel(agents, opts, &Router.complete(draft_prompt(task, plan), &1, opts))

    case successes do
      [] -> {:error, %{stage: :draft, reason: :no_successful_drafts, errors: errors}}
      _ -> {:ok, %{successes: successes, errors: errors}}
    end
  end

  defp run_reviews(task, plan, drafts, opts) do
    review_jobs =
      for reviewer <- Registry.agents(:reviewer, opts),
          draft <- drafts do
        %{reviewer: reviewer, draft: draft}
      end

    {successes, errors} =
      run_parallel(review_jobs, opts, fn %{reviewer: reviewer, draft: draft} ->
        task
        |> review_prompt(plan, draft)
        |> Router.complete(reviewer, opts)
        |> attach_draft(draft)
      end)

    %{successes: successes, errors: errors}
  end

  defp run_synthesizer(task, plan, drafts, reviews, opts) do
    synthesizer =
      :synthesizer
      |> Registry.agents(opts)
      |> List.first()

    case synthesizer do
      nil ->
        %{final: fallback_final(drafts), error: %{stage: :synthesizer, reason: :no_agent}}

      synthesizer ->
        task
        |> synthesis_prompt(plan, drafts, reviews)
        |> Router.complete(synthesizer, opts)
        |> case do
          {:ok, result} ->
            %{final: result.content, synthesizer: result}

          {:error, error} ->
            %{final: fallback_final(drafts), error: error}
        end
    end
  end

  defp run_parallel(items, opts, fun) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    items
    |> Task.async_stream(fun,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, result}}, {successes, errors} ->
        {[result | successes], errors}

      {:ok, {:error, error}}, {successes, errors} ->
        {successes, [error | errors]}

      {:exit, reason}, {successes, errors} ->
        {successes, [%{reason: reason} | errors]}
    end)
    |> then(fn {successes, errors} -> {Enum.reverse(successes), Enum.reverse(errors)} end)
  end

  defp attach_draft({:ok, result}, draft), do: {:ok, Map.put(result, :draft, draft)}
  defp attach_draft({:error, error}, draft), do: {:error, Map.put(error, :draft, draft)}

  defp fallback_final([draft | _]), do: draft.content
  defp fallback_final([]), do: ""

  defp planner_prompt(task) do
    """
    Task: #{task}

    Create a concise implementation plan for this task.
    """
  end

  defp draft_prompt(task, plan) do
    """
    Task: #{task}

    Plan:
    #{plan}

    Produce an implementation draft that follows the plan.
    """
  end

  defp review_prompt(task, plan, draft) do
    """
    Task: #{task}

    Plan:
    #{plan}

    Draft from #{draft.agent.name}:
    #{draft.content}

    Review this draft for correctness, missing pieces, and risks.
    """
  end

  defp synthesis_prompt(task, plan, drafts, reviews) do
    """
    Task: #{task}

    Plan:
    #{plan}

    Drafts:
    #{format_results(drafts)}

    Reviews:
    #{format_results(reviews)}

    Synthesize the final answer. Preserve useful implementation details and resolve review concerns.
    """
  end

  defp format_results(results) do
    results
    |> Enum.map(fn result -> "- #{result.agent.name}: #{result.content}" end)
    |> Enum.join("\n")
  end
end
