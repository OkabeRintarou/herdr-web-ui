defmodule HerdrLiveView.TasksTest do
  use HerdrLiveView.DataCase, async: false

  alias HerdrLiveView.Tasks
  alias HerdrLiveView.Tasks.{Demo, Runner, Workflow}

  test "every demo task round-trips through storage unchanged" do
    for task <- Demo.tasks() do
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
    {:ok, _} = Tasks.create_task(%{"title" => "mine"})
    Tasks.seed_demo!()
    assert [%{title: "mine"}] = Tasks.list_tasks()
  end
end
