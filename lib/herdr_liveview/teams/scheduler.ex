defmodule HerdrLiveView.Teams.Scheduler do
  @moduledoc """
  Starts queued herdr-executed tasks while their team is under its concurrency limit.
  Only the engine manager calls `drain/1`, so starts are serialised and never overshoot.
  """
  import Ecto.Query

  alias HerdrLiveView.{Repo, Tasks, Teams}
  alias HerdrLiveView.Tasks.{Runner, TaskRecord}

  @active [:plan, :implement, :attention]

  def drain(team_id) do
    with %{} = team <- Teams.get_team(team_id) do
      free = team.max_concurrent_tasks - active_count(team_id)

      team_id
      |> queued()
      |> Enum.take(max(free, 0))
      |> Enum.each(fn task ->
        {:ok, _} = Tasks.save_task(Runner.start(task, DateTime.utc_now()))
      end)
    end

    :ok
  end

  def drain_all do
    from(t in TaskRecord, where: t.queued, distinct: true, select: t.team_id)
    |> Repo.all()
    |> Enum.each(&drain/1)
  end

  def active_count(team_id) do
    from(t in TaskRecord,
      where:
        t.team_id == ^team_id and t.executor == "herdr" and t.stage in ^@active and
          not t.queued
    )
    |> Repo.aggregate(:count)
  end

  defp queued(team_id) do
    from(t in TaskRecord,
      where: t.team_id == ^team_id and t.queued,
      order_by: [asc: t.priority, asc: t.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&TaskRecord.to_task/1)
  end
end
