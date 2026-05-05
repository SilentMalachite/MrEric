defmodule MrEric.Runs do
  @moduledoc """
  Context for starting, inspecting, cancelling, and subscribing to runs.
  """

  alias MrEric.Runs.Events
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.RunWorker

  @internal_opts [:subscribe]

  def start_run(task, opts \\ [])

  def start_run(task, opts) when is_binary(task) and is_list(opts) do
    task = String.trim(task)

    if task == "" do
      {:error, :invalid_task}
    else
      run = Run.new(task, Keyword.put_new(opts, :owner_id, "(legacy-no-owner)"))

      if Keyword.get(opts, :subscribe, false) do
        subscribe(run.id)
      end

      worker_opts = Keyword.drop(opts, @internal_opts)

      case RunSupervisor.start_run(run, worker_opts) do
        {:ok, _pid} -> {:ok, run}
        {:error, {:already_started, _pid}} -> {:error, :already_started}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start_run(_task, _opts), do: {:error, :invalid_task}

  def cancel_run(run_id), do: RunWorker.cancel(run_id)

  def approve_tool(run_id, approval_id), do: RunWorker.approve_tool(run_id, approval_id)

  def deny_tool(run_id, approval_id), do: RunWorker.deny_tool(run_id, approval_id)

  def get_run(run_id), do: RunWorker.get_run(run_id)

  def subscribe(run_id), do: Events.subscribe(run_id)

  def unsubscribe(run_id), do: Events.unsubscribe(run_id)

  def broadcast(run_id, event), do: Events.broadcast(run_id, event)
end
