defmodule MrEric.Runs.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for one RunWorker per collaborative run.
  """

  use DynamicSupervisor

  alias MrEric.Runs.RunWorker

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_run(run, opts) do
    DynamicSupervisor.start_child(__MODULE__, {RunWorker, run: run, opts: opts})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
