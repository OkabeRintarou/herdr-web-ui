defmodule HerdrLiveView.Engine.Herdr do
  @moduledoc """
  The herdr operations the engine needs. Swappable via
  `config :herdr_liveview, :engine_herdr, Module` so tests can run without a herdr server.
  """
  alias HerdrLiveView.Herdr.Client

  @callback panes() :: map()
  @callback find_agent(name :: String.t()) :: {:ok, pane_id :: String.t()} | :error
  @callback create_workspace(cwd :: String.t(), label :: String.t()) ::
              {:ok, workspace_id :: String.t(), pane_id :: String.t()} | {:error, term()}
  @callback split_pane(target :: String.t(), cwd :: String.t()) ::
              {:ok, pane_id :: String.t()} | {:error, term()}
  @callback start_agent(name :: String.t(), kind :: String.t(), pane_id :: String.t(), [
              String.t()
            ]) ::
              :ok | {:error, term()}
  @callback prompt(target :: String.t(), text :: String.t()) :: :ok | {:error, term()}

  def impl, do: Application.get_env(:herdr_liveview, :engine_herdr, __MODULE__)

  @behaviour __MODULE__

  # Fresh list rather than the UI's cached copy: the engine acts right after creating panes.
  @impl true
  def panes do
    case Client.request("pane.list", %{}) do
      {:ok, %{"panes" => panes}} -> Map.new(panes, &{&1["pane_id"], &1})
      _ -> %{}
    end
  end

  @impl true
  def find_agent(name) do
    case Client.request("agent.get", %{target: name}) do
      {:ok, %{"agent" => %{"pane_id" => pane}}} -> {:ok, pane}
      _ -> :error
    end
  end

  @impl true
  def create_workspace(cwd, label) do
    with {:ok, %{"workspace" => %{"workspace_id" => ws}, "root_pane" => %{"pane_id" => pane}}} <-
           Client.request("workspace.create", %{cwd: cwd, label: label, focus: false}) do
      {:ok, ws, pane}
    end
  end

  @impl true
  def split_pane(target, cwd) do
    params = %{target_pane_id: target, direction: "right", cwd: cwd, focus: false}

    with {:ok, %{"pane" => %{"pane_id" => pane}}} <- Client.request("pane.split", params) do
      {:ok, pane}
    end
  end

  @impl true
  def start_agent(name, kind, pane_id, args) do
    params = %{name: name, kind: kind, pane_id: pane_id, args: args, timeout_ms: 120_000}

    with {:ok, _} <- Client.request("agent.start", params, timeout: 130_000), do: :ok
  end

  @impl true
  def prompt(target, text) do
    with {:ok, _} <- Client.request("agent.prompt", %{target: target, text: text}), do: :ok
  end
end
