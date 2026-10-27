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
        {Phoenix.PubSub, name: HerdrLiveView.PubSub}
      ] ++
        herdr_children() ++
        [HerdrLiveViewWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HerdrLiveView.Supervisor]
    Supervisor.start_link(children, opts)
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
