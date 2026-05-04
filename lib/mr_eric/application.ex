defmodule MrEric.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    MrEric.Tools.Executor.init_approval_secret()

    children = [
      MrEricWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mr_eric, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MrEric.PubSub},
      {Finch, name: MrEric.Finch},
      {Task.Supervisor, name: MrEric.Agent.TaskSupervisor},
      MrEric.Agent,
      {Registry, keys: :unique, name: MrEric.Runs.Registry},
      MrEric.Runs.RunSupervisor,
      MrEricWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MrEric.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MrEricWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
