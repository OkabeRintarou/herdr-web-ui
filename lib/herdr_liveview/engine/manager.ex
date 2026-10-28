defmodule HerdrLiveView.Engine.Manager do
  @moduledoc """
  Starts task workers at boot and whenever a herdr-executed task is saved, and lets queued
  tasks start as their team frees up. Being a single process, it serialises those starts.
  """
  use GenServer

  alias HerdrLiveView.{Engine, Tasks}
  alias HerdrLiveView.Teams.Scheduler

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Tasks.subscribe()
    {:ok, nil, {:continue, :resume}}
  end

  @impl true
  def handle_continue(:resume, state) do
    Engine.resume_all()
    Scheduler.drain_all()
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_saved, task}, state) do
    Engine.ensure_worker(task)

    if task.executor == "herdr" and task.team_id, do: Scheduler.drain(task.team_id)

    {:noreply, state}
  end
end
