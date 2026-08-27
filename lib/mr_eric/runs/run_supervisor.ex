defmodule MrEric.Runs.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for one RunWorker per collaborative run.

  `max_children` caps how many run workers may exist at once (Spec D).
  `DynamicSupervisor.start_child/2` returns `{:error, :max_children}` at the
  cap; `MrEric.Runs.start_run/3` translates that into the domain error
  `{:error, :too_many_runs}`.

  The cap counts *workers*, not streaming runs: a finished run keeps its slot
  until `RunWorker` reaps itself after `terminal_run_ttl_ms`.
  """

  use DynamicSupervisor

  alias MrEric.Runs.Limits
  alias MrEric.Runs.RunWorker

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  def start_run(run, opts, supervisor \\ __MODULE__) do
    DynamicSupervisor.start_child(supervisor, {RunWorker, run: run, opts: opts})
  end

  @impl true
  def init(opts) do
    max_children = Keyword.get(opts, :max_children, Limits.fetch!(:max_concurrent_runs))

    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_children)
  end
end
