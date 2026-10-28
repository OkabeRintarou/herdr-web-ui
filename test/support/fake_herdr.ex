defmodule HerdrLiveView.FakeHerdr do
  @moduledoc "Stand-in for `HerdrLiveView.Engine.Herdr`: records calls to the test process and fakes panes."
  @behaviour HerdrLiveView.Engine.Herdr

  use Agent

  def start_link({test_pid, host_id}) do
    Agent.start_link(
      fn -> %{test: test_pid, host_id: host_id, panes: %{}, next: 1, blocked: false} end,
      name: __MODULE__
    )
  end

  @doc "Makes agents start stuck at a dialog: start reports not-ready and prompts are rejected."
  def block_agents(blocked?), do: Agent.update(__MODULE__, &%{&1 | blocked: blocked?})

  def set_status(pane_id, status) do
    Agent.update(__MODULE__, &put_in(&1, [:panes, pane_id, "agent_status"], status))
    %{host_id: host_id, panes: panes} = Agent.get(__MODULE__, & &1)

    Phoenix.PubSub.broadcast(
      HerdrLiveView.PubSub,
      HerdrLiveView.Herdr.Panes.topic(host_id),
      {:herdr_panes, :connected, panes}
    )
  end

  @impl true
  def panes(_host), do: Agent.get(__MODULE__, & &1.panes)

  @impl true
  def find_agent(_host, name) do
    Agent.get(__MODULE__, fn s ->
      Enum.find_value(s.panes, :error, fn {pane, p} -> if p["name"] == name, do: {:ok, pane} end)
    end)
  end

  @impl true
  def create_workspace(_host, cwd, label) do
    pane = new_pane()
    notify({:create_workspace, cwd, label, pane})
    {:ok, "w9", pane}
  end

  @impl true
  def split_pane(_host, target, cwd) do
    pane = new_pane()
    notify({:split_pane, target, cwd, pane})
    {:ok, pane}
  end

  @impl true
  def start_agent(_host, name, kind, pane_id, _args) do
    Agent.update(__MODULE__, fn s ->
      s
      |> put_in([:panes, pane_id, "agent"], kind)
      |> put_in([:panes, pane_id, "name"], name)
    end)

    notify({:start_agent, name, pane_id})

    if Agent.get(__MODULE__, & &1.blocked),
      do: {:error, {:herdr, %{"code" => "agent_not_ready", "message" => "blocked"}}},
      else: :ok
  end

  @impl true
  def prompt(_host, target, text) do
    if Agent.get(__MODULE__, & &1.blocked) do
      notify({:prompt_rejected, target})
      {:error, {:herdr, %{"code" => "agent_blocked", "message" => "blocked"}}}
    else
      notify({:prompt, target, text})
      :ok
    end
  end

  defp new_pane do
    Agent.get_and_update(__MODULE__, fn s ->
      pane = "w9:p#{s.next}"
      {pane, %{s | next: s.next + 1, panes: Map.put(s.panes, pane, %{"pane_id" => pane})}}
    end)
  end

  defp notify(msg), do: send(Agent.get(__MODULE__, & &1.test), {:herdr, msg})
end
