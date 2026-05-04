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

  @doc """
  Streams collaborative run progress to `pid`.

  Events use the same shape as the Run PubSub events. `RunWorker` passes a
  `:run_id` option so these events can be forwarded to `"runs:\#{run_id}"`.
  """
  def stream(task, pid, opts \\ [])

  def stream(task, pid, opts) when is_binary(task) and task != "" and is_pid(pid) do
    with {:ok, planner} <- stream_planner(task, pid, opts) do
      draft_result = stream_drafts(task, planner.content, pid, opts)
      review_result = stream_reviews(task, planner.content, draft_result.successes, pid, opts)

      stream_synthesizer(
        task,
        planner.content,
        draft_result.successes,
        draft_result.errors,
        review_result.successes,
        review_result.errors,
        pid,
        opts
      )
    else
      {:error, reason} ->
        send_event(pid, :run_failed, %{error: reason}, opts)
        {:error, reason}
    end
  end

  def stream(_task, pid, opts) when is_pid(pid) do
    send_event(pid, :run_failed, %{error: :invalid_task}, opts)
    {:error, :invalid_task}
  end

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

  defp stream_planner(task, pid, opts) do
    :planner
    |> Registry.agents(opts)
    |> List.first()
    |> case do
      nil ->
        error = %{stage: :planner, reason: :no_agent}
        send_event(pid, :stage_failed, %{role: :planner, error: error}, opts)
        {:error, error}

      planner ->
        send_event(pid, :stage_started, %{role: :planner, agent: planner}, opts)

        case Router.complete(planner_prompt(task), planner, opts) do
          {:ok, result} ->
            emit_stage_success(pid, :planner, result, opts)
            {:ok, result}

          {:error, error} ->
            send_event(pid, :stage_failed, %{role: :planner, agent: planner, error: error}, opts)
            {:error, error}
        end
    end
  end

  defp stream_drafts(task, plan, pid, opts) do
    :draft
    |> Registry.agents(opts)
    |> tag_agents([:local_drafter, :cloud_drafter])
    |> stream_parallel(opts, fn {role, agent} ->
      send_event(pid, :stage_started, %{role: role, agent: agent}, opts)

      task
      |> draft_prompt(plan)
      |> Router.complete(agent, opts)
      |> case do
        {:ok, result} ->
          emit_stage_success(pid, role, result, opts)
          {:ok, result}

        {:error, error} ->
          send_event(pid, :stage_failed, %{role: role, agent: agent, error: error}, opts)
          {:error, Map.put(error, :role, role)}
      end
    end)
  end

  defp stream_reviews(_task, _plan, [], _pid, _opts) do
    %{successes: [], errors: []}
  end

  defp stream_reviews(task, plan, drafts, pid, opts) do
    review_jobs =
      for {role, reviewer} <- Registry.agents(:reviewer, opts) |> tag_agents([:critic, :reviewer]),
          draft <- drafts do
        %{role: role, reviewer: reviewer, draft: draft}
      end

    stream_parallel(review_jobs, opts, fn %{role: role, reviewer: reviewer, draft: draft} ->
      send_event(pid, :stage_started, %{role: role, agent: reviewer}, opts)

      task
      |> review_prompt(plan, draft)
      |> Router.complete(reviewer, opts)
      |> attach_draft(draft)
      |> case do
        {:ok, result} ->
          emit_stage_success(pid, role, result, opts)
          {:ok, result}

        {:error, error} ->
          send_event(pid, :stage_failed, %{role: role, agent: reviewer, error: error}, opts)
          {:error, Map.put(error, :role, role)}
      end
    end)
  end

  defp stream_synthesizer(
         task,
         plan,
         drafts,
         draft_errors,
         reviews,
         review_errors,
         pid,
         opts
       ) do
    :synthesizer
    |> Registry.agents(opts)
    |> List.first()
    |> case do
      nil ->
        error = %{stage: :synthesizer, reason: :no_agent}
        send_event(pid, :stage_failed, %{role: :synthesizer, error: error}, opts)
        send_event(pid, :run_failed, %{error: error}, opts)
        {:error, error}

      synthesizer ->
        send_event(pid, :stage_started, %{role: :synthesizer, agent: synthesizer}, opts)

        task
        |> synthesis_prompt(plan, drafts, reviews, draft_errors ++ review_errors)
        |> Router.complete(synthesizer, opts)
        |> case do
          {:ok, result} ->
            emit_stage_success(pid, :synthesizer, result, opts)

            final = result.content || ""

            run_result = %{
              task: task,
              plan: plan,
              drafts: drafts,
              draft_errors: draft_errors,
              reviews: reviews,
              review_errors: review_errors,
              final: final,
              synthesizer: result
            }

            send_event(pid, :run_completed, %{final: final, result: run_result}, opts)
            {:ok, run_result}

          {:error, error} ->
            send_event(
              pid,
              :stage_failed,
              %{role: :synthesizer, agent: synthesizer, error: error},
              opts
            )

            send_event(pid, :run_failed, %{error: error}, opts)
            {:error, error}
        end
    end
  end

  defp stream_parallel(items, opts, fun) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    items
    |> Task.async_stream(fun,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{successes: [], errors: []}, fn
      {:ok, {:ok, result}}, acc ->
        %{acc | successes: [result | acc.successes]}

      {:ok, {:error, error}}, acc ->
        %{acc | errors: [error | acc.errors]}

      {:exit, reason}, acc ->
        %{acc | errors: [%{reason: reason} | acc.errors]}
    end)
    |> then(fn result ->
      %{successes: Enum.reverse(result.successes), errors: Enum.reverse(result.errors)}
    end)
  end

  defp tag_agents(agents, roles) do
    agents
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      role = Enum.at(roles, index, List.last(roles))
      {role, agent}
    end)
  end

  defp emit_stage_success(pid, role, result, opts) do
    content = result.content || ""

    if content != "" do
      send_event(pid, :stage_chunk, %{role: role, agent: result.agent, chunk: content}, opts)
    end

    send_event(pid, :stage_completed, %{role: role, agent: result.agent, content: content}, opts)
  end

  defp send_event(pid, event, payload, opts) do
    payload =
      case Keyword.get(opts, :run_id) do
        nil -> payload
        run_id -> Map.put_new(payload, :run_id, run_id)
      end

    send(pid, {event, payload})
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
    synthesis_prompt(task, plan, drafts, reviews, [])
  end

  defp synthesis_prompt(task, plan, drafts, reviews, errors) do
    """
    Task: #{task}

    Plan:
    #{plan}

    Drafts:
    #{format_results(drafts)}

    Reviews:
    #{format_results(reviews)}

    Failed stages:
    #{format_errors(errors)}

    Synthesize the final answer. Preserve useful implementation details and resolve review concerns.
    """
  end

  defp format_results(results) do
    results
    |> Enum.map(fn result -> "- #{result.agent.name}: #{result.content}" end)
    |> Enum.join("\n")
  end

  defp format_errors([]), do: "- none"

  defp format_errors(errors) do
    errors
    |> Enum.map(fn error ->
      agent = Map.get(error, :agent, %{})
      name = Map.get(agent, :name, Map.get(error, :role, "agent"))
      reason = Map.get(error, :reason, error)

      "- #{name}: #{inspect(reason)}"
    end)
    |> Enum.join("\n")
  end
end
