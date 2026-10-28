defmodule HerdrLiveView.Tasks do
  @moduledoc """
  Task storage boundary. Callers only see plain task maps; the Repo (SQLite by default,
  any Ecto adapter by config) stays behind this module. Every save is broadcast.
  """
  alias HerdrLiveView.Repo
  alias HerdrLiveView.Tasks.{Demo, Runner, TaskRecord}

  import Ecto.Query

  @topic "tasks"

  def subscribe, do: Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, @topic)

  def list_tasks, do: TaskRecord |> Repo.all() |> Enum.map(&TaskRecord.to_task/1)

  def list_tasks(project_id) do
    from(t in TaskRecord, where: t.project_id == ^project_id)
    |> Repo.all()
    |> Enum.map(&TaskRecord.to_task/1)
  end

  @doc "Per-project counts by stage, e.g. `%{\"p-1\" => %{todo: 2, attention: 1}}`."
  def stage_counts do
    from(t in TaskRecord,
      group_by: [t.project_id, t.stage],
      select: {t.project_id, t.stage, count()}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {project, stage, n}, acc ->
      Map.update(acc, project, %{stage => n}, &Map.put(&1, stage, n))
    end)
  end

  def list_attention do
    from(t in TaskRecord, where: t.stage == :attention, order_by: t.stage_since)
    |> Repo.all()
    |> Enum.map(&TaskRecord.to_task/1)
  end

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
  def seed_demo!(project) do
    if Repo.aggregate(TaskRecord, :count) == 0 do
      Enum.each(Demo.tasks(project), &({:ok, _} = save_task(&1)))
    end

    :ok
  end

  @doc "Moves tasks created before projects existed into `project`."
  def adopt_orphans!(project) do
    from(t in TaskRecord, where: is_nil(t.project_id))
    |> Repo.update_all(set: [project_id: project.id])

    from(t in TaskRecord, where: t.workdir == "")
    |> Repo.update_all(set: [workdir: project.path])

    :ok
  end

  @doc "Gives tasks created before teams existed the project's default team."
  def assign_team!(project_id, team_id) do
    from(t in TaskRecord, where: t.project_id == ^project_id and is_nil(t.team_id))
    |> Repo.update_all(set: [team_id: team_id])

    :ok
  end
end
