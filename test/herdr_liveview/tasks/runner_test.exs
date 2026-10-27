defmodule HerdrLiveView.Tasks.RunnerTest do
  use ExUnit.Case, async: true

  alias HerdrLiveView.Tasks.{Runner, Workflow}

  @t0 ~U[2026-10-27 08:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, minutes * 60, :second)

  defp new(workflow), do: Runner.new(%{"title" => "t", "workflow" => workflow}, @t0)

  defp play(task, verdicts) do
    Enum.reduce(Enum.with_index(verdicts, 1), task, fn {v, i}, task ->
      Runner.verdict(task, v, nil, at(i))
    end)
  end

  test "templates and lead proposals pass validation" do
    task = new("lead")

    for wf <- Workflow.templates() ++ [Workflow.propose(task, 1), Workflow.propose(task, 2)] do
      assert Enum.all?(Workflow.validate(wf), &elem(&1, 1)), "#{wf.name} v#{wf.version}"
    end
  end

  test "validation flags loops without a cap and unreachable completion" do
    wf = Workflow.quick()

    uncapped =
      put_in(wf.transitions["code_review"], [%{on: "changes_requested", to: "fix", max: nil}])

    checks = Map.new(Workflow.validate(uncapped))

    refute checks["每个循环都有上限"]
    refute checks["能到达完成"]
  end

  test "verdicts follow transitions, including loops back" do
    task = new("standard") |> Runner.start(@t0) |> play(~w(done pass done changes_requested done))

    assert task.step == "code_review"
    assert task.visits["code_review"] == 2
    assert task.edge_counts["code_review:changes_requested"] == 1
    assert task.last_bounce == "代码评审 → 要修改"
  end

  test "needs_replan from implementation returns to planning" do
    task = new("standard") |> Runner.start(@t0) |> play(~w(done pass needs_replan))

    assert task.step == "plan"
    assert task.stage == :plan
    assert task.visits["plan"] == 2
  end

  test "hitting a loop cap escalates to a human, who can grant one more pass" do
    task =
      new("quick")
      |> Runner.start(@t0)
      |> play(~w(done changes_requested done changes_requested done changes_requested))

    assert task.stage == :attention
    assert %{kind: :max_loops, key: "code_review:changes_requested"} = task.attention
    assert task.step == "code_review"

    task = Runner.extend(task, at(10))
    assert task.step == "fix"
    assert task.attention == nil
  end

  test "human accept step waits in attention and completes the task" do
    task = new("quick") |> Runner.start(@t0) |> play(~w(done pass))
    assert %{kind: :accept} = task.attention
    assert task.stage == :attention

    task = Runner.verdict(task, "pass", nil, at(5))
    assert task.stage == :done
    assert task.step == nil
  end

  test "lead flow: design, propose, redesign with diff, approve" do
    task = new("lead") |> Runner.start(@t0)
    assert task.step == "design"
    assert task.stage == :plan

    task = Runner.propose(task, Workflow.propose(task, 1), at(3))
    assert %{kind: :workflow_approval} = task.attention

    task = Runner.redesign(task, at(4))
    assert task.step == "design"
    assert task.previous_workflow.version == 1

    task = Runner.propose(task, Workflow.propose(task, 2, "太重了"), at(6))
    assert %{removed: removed} = Workflow.diff(task.previous_workflow, task.proposal.workflow)
    assert "规划评审" in removed

    task = Runner.approve_workflow(task, at(7))
    assert task.workflow.version == 2
    assert task.step == "plan"
    assert task.attention == nil
  end
end
