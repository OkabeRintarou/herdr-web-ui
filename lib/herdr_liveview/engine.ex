defmodule HerdrLiveView.Engine do
  @moduledoc """
  Supervises one `TaskWorker` per herdr-executed task that is not finished, starting workers
  at boot and whenever such a task is saved.
  """
  use Supervisor

  alias HerdrLiveView.Engine.TaskWorker
  alias HerdrLiveView.Tasks

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: HerdrLiveView.Engine.Registry},
      {DynamicSupervisor, name: HerdrLiveView.Engine.Workers, strategy: :one_for_one},
      HerdrLiveView.Engine.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def ensure_worker(%{executor: "herdr", stage: stage, id: id}) when stage != :done do
    case Registry.lookup(HerdrLiveView.Engine.Registry, id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(HerdrLiveView.Engine.Workers, {TaskWorker, id}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def ensure_worker(_task), do: :ignore

  def resume_all, do: Enum.each(Tasks.list_tasks(), &ensure_worker/1)
end
