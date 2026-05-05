defmodule MrEric.Runs do
  @moduledoc """
  Context for starting, inspecting, cancelling, and subscribing to runs.
  """

  alias MrEric.Runs.Events
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.RunWorker

  @internal_opts [:subscribe]

  def start_run(task, owner_id, opts \\ [])

  def start_run(task, owner_id, opts)
      when is_binary(task) and is_binary(owner_id) and is_list(opts) do
    task = String.trim(task)

    if task == "" do
      {:error, :invalid_task}
    else
      run = Run.new(task, Keyword.put(opts, :owner_id, owner_id))

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

  def start_run(_task, _owner_id, _opts), do: {:error, :invalid_task}

  def cancel_run(run_id, owner_id) when is_binary(owner_id) do
    RunWorker.cancel(run_id, owner_id)
  end

  def approve_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    RunWorker.approve_tool(run_id, approval_id, owner_id)
  end

  def deny_tool(run_id, approval_id, owner_id) when is_binary(owner_id) do
    RunWorker.deny_tool(run_id, approval_id, owner_id)
  end

  def get_run(run_id), do: RunWorker.get_run(run_id)

  def subscribe(run_id), do: Events.subscribe(run_id)

  def unsubscribe(run_id), do: Events.unsubscribe(run_id)

  def broadcast(run_id, event), do: Events.broadcast(run_id, event)
end
