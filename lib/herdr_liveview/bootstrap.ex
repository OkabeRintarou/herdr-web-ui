defmodule HerdrLiveView.Bootstrap do
  @moduledoc """
  Runs once at boot, after migrations and before the engine: makes sure the configured local
  host and a default project exist, moves pre-project tasks into it, then connects to hosts.
  """
  alias HerdrLiveView.{Hosts, Projects, Tasks}

  def child_spec(_opts),
    do: %{id: __MODULE__, start: {__MODULE__, :run, []}, restart: :temporary}

  # Returning :ignore makes the supervisor wait for this to finish before the next child.
  def run do
    host =
      Hosts.ensure_managed_local!(Application.fetch_env!(:herdr_liveview, :herdr_socket_path))

    project = Projects.ensure_default!(host)
    Tasks.adopt_orphans!(project)
    if Application.get_env(:herdr_liveview, :seed_demo, false), do: Tasks.seed_demo!(project)
    Hosts.connect_all()
    :ignore
  end
end
