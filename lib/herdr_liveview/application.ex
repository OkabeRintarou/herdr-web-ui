defmodule HerdrLiveView.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        HerdrLiveViewWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:herdr_liveview, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: HerdrLiveView.PubSub},
        HerdrLiveView.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:herdr_liveview, :ecto_repos),
         skip: not Application.get_env(:herdr_liveview, :migrate_on_boot, true)}
      ] ++
        seed_children() ++
        herdr_children() ++
        if(Application.get_env(:herdr_liveview, :start_engine, true),
          do: [HerdrLiveView.Engine],
          else: []
        ) ++
        [HerdrLiveViewWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HerdrLiveView.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp seed_children do
    if Application.get_env(:herdr_liveview, :seed_demo, false),
      do: [{Task, &HerdrLiveView.Tasks.seed_demo!/0}],
      else: []
  end

  defp herdr_children do
    if Application.get_env(:herdr_liveview, :start_herdr, true),
      do: [HerdrLiveView.Herdr.Panes],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HerdrLiveViewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
