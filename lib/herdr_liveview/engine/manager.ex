defmodule HerdrLiveView.Engine.Manager do
  @moduledoc "Starts task workers at boot and whenever a herdr-executed task is saved."
  use GenServer

  alias HerdrLiveView.{Engine, Tasks}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Tasks.subscribe()
    {:ok, nil, {:continue, :resume}}
  end

  @impl true
  def handle_continue(:resume, state) do
    Engine.resume_all()
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_saved, task}, state) do
    Engine.ensure_worker(task)
    {:noreply, state}
  end
end
