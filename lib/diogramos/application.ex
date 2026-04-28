defmodule Diogramos.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Forward warnings + errors to Sentry. No-ops when SENTRY_DSN is unset.
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        DiogramosWeb.Telemetry,
        Diogramos.Repo
      ] ++
        cluster_children(topologies) ++
        [
          {Phoenix.PubSub, name: Diogramos.PubSub},
          Diogramos.Diagrams.Authority,
          DiogramosWeb.Presence,
          DiogramosWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Diogramos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DiogramosWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp cluster_children([]), do: []

  defp cluster_children(topologies) do
    [{Cluster.Supervisor, [topologies, [name: Diogramos.ClusterSupervisor]]}]
  end
end
