defmodule HerdrLiveView.Tasks do
  @moduledoc """
  Task storage boundary. Callers only see plain task maps; the Repo (SQLite by default,
  any Ecto adapter by config) stays behind this module. Every save is broadcast.
  """
  alias HerdrLiveView.Repo
  alias HerdrLiveView.Tasks.{Demo, Runner, TaskRecord}

  @topic "tasks"

  def subscribe, do: Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, @topic)

  def list_tasks, do: TaskRecord |> Repo.all() |> Enum.map(&TaskRecord.to_task/1)

  def get_task(id) do
    case Repo.get(TaskRecord, id) do
      nil -> nil
      record -> TaskRecord.to_task(record)
    end
  end

  def create_task(attrs), do: attrs |> Runner.new() |> save_task()

  @doc "Inserts or replaces the whole task; returns the same domain map it was given."
  def save_task(task) do
    changeset = TaskRecord.changeset(%TaskRecord{}, TaskRecord.from_task(task))

    with {:ok, _record} <-
           Repo.insert(changeset,
             on_conflict: {:replace_all_except, [:id, :inserted_at]},
             conflict_target: :id
           ) do
      Phoenix.PubSub.broadcast(HerdrLiveView.PubSub, @topic, {:task_saved, task})
      {:ok, task}
    end
  end

  @doc "Fills an empty store with the demo tasks so the board has something to show."
  def seed_demo! do
    if Repo.aggregate(TaskRecord, :count) == 0 do
      Enum.each(Demo.tasks(), &({:ok, _} = save_task(&1)))
    end

    :ok
  end
end
