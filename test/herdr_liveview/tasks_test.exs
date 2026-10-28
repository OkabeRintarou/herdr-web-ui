defmodule HerdrLiveView.TasksTest do
  use HerdrLiveView.DataCase, async: false

  import HerdrLiveView.Fixtures

  alias HerdrLiveView.Tasks
  alias HerdrLiveView.Tasks.{Demo, Runner, Workflow}

  test "every demo task round-trips through storage unchanged" do
    for task <- Demo.tasks(project_fixture()) do
      assert {:ok, ^task} = Tasks.save_task(task)
      assert Tasks.get_task(task.id) == task, "#{task.id} changed after reload"
    end
  end

  test "saving again replaces the stored task and broadcasts it" do
    Tasks.subscribe()
    {:ok, task} = Tasks.create_task(%{"title" => "persist me", "workflow" => "quick"})
    assert_receive {:task_saved, %{id: id}} when id == task.id

    started = Runner.start(task, DateTime.utc_now())
    {:ok, _} = Tasks.save_task(started)

    assert %{step: "implement", stage: :implement} = Tasks.get_task(task.id)
    assert length(Tasks.list_tasks()) == 1
  end

  test "a stored lead proposal comes back with its validation checks" do
    task =
      Runner.new(%{"title" => "lead", "workflow" => "lead"}) |> Runner.start(DateTime.utc_now())

    task = Runner.propose(task, Workflow.propose(task), DateTime.utc_now())
    {:ok, _} = Tasks.save_task(task)

    assert %{proposal: %{checks: checks, workflow: %{source: :lead}}} = Tasks.get_task(task.id)
    assert Enum.all?(checks, &elem(&1, 1))
  end

  test "seed_demo! only fills an empty store" do
    project = project_fixture()
    {:ok, _} = Tasks.create_task(%{"title" => "mine", "project_id" => project.id})
    Tasks.seed_demo!(project)
    assert [%{title: "mine"}] = Tasks.list_tasks()
  end

  test "tasks from before projects existed are moved into a project" do
    project = project_fixture()
    {:ok, orphan} = Tasks.create_task(%{"title" => "old"})

    :ok = Tasks.adopt_orphans!(project)

    assert %{project_id: project_id, workdir: workdir} = Tasks.get_task(orphan.id)
    assert {project_id, workdir} == {project.id, project.path}
    assert %{^project_id => %{todo: 1}} = Tasks.stage_counts()
  end
end
