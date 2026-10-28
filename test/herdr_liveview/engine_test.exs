defmodule HerdrLiveView.EngineTest do
  use HerdrLiveView.DataCase, async: false

  import HerdrLiveView.Fixtures

  alias HerdrLiveView.{Engine, FakeHerdr, Tasks, Teams}
  alias HerdrLiveView.Engine.Step
  alias HerdrLiveView.Tasks.Runner

  setup do
    dir = scratch_dir!()
    project = project_fixture(%{path: dir})
    start_supervised!({FakeHerdr, {self(), project.host_id}})
    start_supervised!(Engine)
    # on_exit runs LIFO: stop workers before the sandbox owner rolls back underneath them
    on_exit(fn -> if pid = Process.whereis(Engine), do: Supervisor.stop(pid) end)
    Tasks.subscribe()

    task =
      Runner.new(%{
        "title" => "加个 flag",
        "workflow" => "quick",
        "executor" => "herdr",
        "project_id" => project.id,
        "workdir" => project.path
      })

    %{task: task, dir: dir}
  end

  defp start(task) do
    {:ok, task} = Tasks.save_task(Runner.start(task, DateTime.utc_now()))
    task
  end

  defp write_result(task, json) do
    File.write!(Step.result_path(task), Jason.encode!(json))
  end

  defp await_task(fun) do
    receive do
      {:task_saved, task} -> if fun.(task), do: task, else: await_task(fun)
    after
      2_000 -> flunk("task never reached the expected state")
    end
  end

  test "dispatches each step to its role's agent and follows the verdicts", %{task: task} do
    task = start(task)

    assert_receive {:herdr, {:create_workspace, _cwd, "task " <> _, coder_pane}}
    assert_receive {:herdr, {:start_agent, coder, ^coder_pane}}
    assert coder == "#{task.id}-coder"
    assert_receive {:herdr, {:prompt, ^coder, prompt}}
    assert prompt =~ Step.result_path(task)
    assert prompt =~ "- done："

    task = await_task(&(&1.pane_id == coder_pane))
    write_result(task, %{verdict: "done", summary: "加好了"})
    FakeHerdr.set_status(coder_pane, "idle")

    # the reviewer gets its own pane next to the coder's
    assert_receive {:herdr, {:split_pane, ^coder_pane, _cwd, reviewer_pane}}
    assert_receive {:herdr, {:start_agent, reviewer, ^reviewer_pane}}
    assert_receive {:herdr, {:prompt, ^reviewer, _}}

    task = await_task(&(&1.step == "code_review" and &1.pane_id == reviewer_pane))
    assert [%{status: :done, output: "完成：加好了"}, %{label: "代码评审"}] = task.timeline

    write_result(task, %{verdict: "changes_requested", summary: "少了测试"})
    FakeHerdr.set_status(reviewer_pane, "idle")

    # coder is reused for the fix and hears what the reviewer said
    assert_receive {:herdr, {:prompt, ^coder, fix_prompt}}
    assert fix_prompt =~ "要修改：少了测试"
    refute_received {:herdr, {:start_agent, _, _}}
    assert %{step: "fix", agents: %{"coder" => _, "reviewer" => _}} = Tasks.get_task(task.id)
  end

  test "nudges once when the agent stops without a result, then escalates", %{task: task} do
    start(task)
    assert_receive {:herdr, {:prompt, _coder, _}}
    pane = await_task(& &1.pane_id).pane_id

    FakeHerdr.set_status(pane, "working")
    FakeHerdr.set_status(pane, "idle")
    assert_receive {:herdr, {:prompt, _coder, "你还没有写结果文件" <> _}}

    FakeHerdr.set_status(pane, "working")
    FakeHerdr.set_status(pane, "idle")
    task = await_task(&(&1.stage == :attention))
    assert task.attention.message =~ "仍未交付结果"
  end

  test "an invalid verdict is sent back to the agent with the reason", %{task: task} do
    task = start(task)
    assert_receive {:herdr, {:prompt, _coder, _}}
    pane = await_task(& &1.pane_id).pane_id

    write_result(task, %{verdict: "pass"})
    FakeHerdr.set_status(pane, "idle")

    assert_receive {:herdr, {:prompt, _coder, text}}
    assert text =~ "verdict 必须是 done 之一"
  end

  test "a blocked agent raises attention that lifts once the agent works again", %{task: task} do
    start(task)
    assert_receive {:herdr, {:prompt, _coder, _}}
    pane = await_task(& &1.pane_id).pane_id

    FakeHerdr.set_status(pane, "blocked")
    assert %{attention: %{key: "agent_blocked"}} = await_task(&(&1.stage == :attention))

    FakeHerdr.set_status(pane, "working")
    assert %{attention: nil, stage: :implement} = await_task(&(&1.stage == :implement))
  end

  test "an agent stuck at a startup dialog waits for a human, then gets its prompt", %{
    task: task
  } do
    FakeHerdr.block_agents(true)
    start(task)

    assert_receive {:herdr, {:start_agent, coder, pane}}
    assert_receive {:herdr, {:prompt_rejected, ^coder}}
    assert %{attention: %{key: "agent_blocked"}} = await_task(&(&1.stage == :attention))

    # the human answers the dialog in herdr; the agent settles and the step is re-sent
    FakeHerdr.block_agents(false)
    FakeHerdr.set_status(pane, "idle")

    assert_receive {:herdr, {:prompt, ^coder, prompt}}
    assert prompt =~ "实现"
    refute_received {:herdr, {:start_agent, _, _}}
  end

  test "a restarted engine resumes without re-sending the prompt", %{task: task} do
    start(task)
    assert_receive {:herdr, {:prompt, _coder, _}}
    task = await_task(&(&1.agents["coder"]["step"] == "implement-1"))

    stop_supervised!(Engine)
    start_supervised!(Engine)
    refute_receive {:herdr, {:prompt, _, _}}, 300

    write_result(task, %{verdict: "done"})
    FakeHerdr.set_status(task.pane_id, "idle")
    assert %{step: "code_review"} = await_task(&(&1.step == "code_review"))
  end

  test "an agent that already exists under the role's name is adopted, not duplicated", %{
    task: task
  } do
    {:ok, _ws, pane} = FakeHerdr.create_workspace(nil, "/elsewhere", "pre-existing")
    :ok = FakeHerdr.start_agent(nil, "#{task.id}-coder", "copilot", pane, [])
    assert_receive {:herdr, {:create_workspace, "/elsewhere", _, ^pane}}
    assert_receive {:herdr, {:start_agent, _, ^pane}}

    start(task)

    assert_receive {:herdr, {:prompt, _coder, _}}
    refute_received {:herdr, {:create_workspace, _, _, _}}
    refute_received {:herdr, {:start_agent, _, _}}
    assert %{pane_id: ^pane} = await_task(&(&1.pane_id == pane))
  end

  test "in a git project the agents work in the task's own worktree", %{task: task, dir: dir} do
    HerdrLiveView.WorktreesTest.init_repo!(dir)
    task = start(task)

    worktree = Path.join([dir, ".herdr-worktrees", task.id])
    assert_receive {:herdr, {:create_workspace, ^worktree, _, _}}
    assert_receive {:herdr, {:prompt, _, prompt}}
    assert prompt =~ Path.join([worktree, ".herdr-tasks", task.id])

    assert %{branch: branch, workdir: ^worktree} = await_task(&(&1.worktree == worktree))
    assert branch == "herdr/#{task.id}"
    settle(task.id)
  end

  describe "lead design" do
    setup %{task: task} do
      team = Teams.default_team(task.project_id)

      {:ok, _} =
        Teams.create_member(team.id, %{
          "name" => "cc2",
          "role" => "coder",
          "agent_kind" => "claude"
        })

      %{task: %{task | workflow: nil, workflow_source: "lead", team_id: team.id}}
    end

    defp plan(roles \\ %{}) do
      %{
        name: "小改动",
        rationale: "改动小，直接做再评审",
        steps: [
          %{
            id: "build",
            label: "实现",
            role: roles[:build] || "coder",
            phase: "implement",
            instructions: "实现并提交，说明写到 {dir}/notes.md"
          },
          %{id: "check", label: "评审", role: "reviewer", phase: "implement"},
          %{id: "accept", label: "验收", role: "human"}
        ],
        transitions: %{
          build: [%{on: "done", to: "check"}],
          check: [%{on: "pass", to: "accept"}, %{on: "changes_requested", to: "build", max: 2}],
          accept: [%{on: "pass", to: "done"}]
        },
        assignments: %{coder: "cc2"}
      }
    end

    test "the lead's plan goes back until it passes the checks, then waits for approval", %{
      task: task
    } do
      task = start(task)

      assert_receive {:herdr, {:agent_command, lead, _, _}}
      assert lead == "#{task.id}-lead"
      assert_receive {:herdr, {:prompt, ^lead, prompt}}
      assert prompt =~ "cc2（角色 coder，claude）"
      assert prompt =~ "标准流程："
      plan_path = Step.result_path(%{task | step: "design", visits: %{"design" => 1}})
      assert prompt =~ plan_path
      assert plan_path =~ "design-1.plan.json"

      pane = await_task(& &1.pane_id).pane_id
      File.write!(plan_path, Jason.encode!(plan(%{build: "analyst"})))
      FakeHerdr.set_status(pane, "idle")

      assert_receive {:herdr, {:prompt, ^lead, nudge}}
      assert nudge =~ "Team 里没有这些角色：analyst"

      File.write!(plan_path, Jason.encode!(plan()))
      FakeHerdr.set_status(pane, "working")
      FakeHerdr.set_status(pane, "idle")

      task = await_task(&(&1.stage == :attention))
      assert %{attention: %{kind: :workflow_approval}, proposal: %{workflow: wf}} = task
      assert %{source: :lead, version: 1, assignments: %{"coder" => "cc2"}} = wf
      assert Enum.all?(Tasks.get_task(task.id).proposal.checks, &elem(&1, 1))

      # approved: the step goes to the member the lead picked, with the lead's instructions
      {:ok, _} = Tasks.save_task(Runner.approve_workflow(task, DateTime.utc_now()))
      assert_receive {:herdr, {:agent_command, coder, "claude", _}}
      assert coder == "#{task.id}-cc2"
      assert_receive {:herdr, {:prompt, ^coder, step_prompt}}
      assert step_prompt =~ "说明写到 #{Step.task_dir(task)}/notes.md"
      settle(task.id)
    end

    test "a redesign asks the same lead again with the feedback and the previous version", %{
      task: task
    } do
      task = start(task)
      assert_receive {:herdr, {:agent_command, _, _, _}}
      assert_receive {:herdr, {:prompt, lead, _}}
      pane = await_task(& &1.pane_id).pane_id

      File.write!(Step.result_path(Tasks.get_task(task.id)), Jason.encode!(plan()))
      FakeHerdr.set_status(pane, "idle")
      task = await_task(&(&1.stage == :attention))

      {:ok, _} = Tasks.save_task(Runner.redesign(task, DateTime.utc_now(), "去掉评审"))

      assert_receive {:herdr, {:prompt, ^lead, prompt}}
      assert prompt =~ "第 2 版"
      assert prompt =~ "要求重新设计：去掉评审"
      assert prompt =~ "上一版流程（v1）"
      assert prompt =~ "design-2.plan.json"
      refute_received {:herdr, {:agent_command, _, _, _}}
      settle(task.id)
    end
  end

  test "simulated tasks are never picked up", %{task: task} do
    start(%{task | executor: "simulated"})
    refute_receive {:herdr, _}, 200
  end

  test "the team's member decides which agent CLI runs, with its arguments and duty", %{
    task: task
  } do
    {:ok, team} = Teams.create_team(task.project_id, %{"name" => "claude 队"})

    for {name, role} <- [{"cc", "coder"}, {"rev", "reviewer"}] do
      {:ok, _} =
        Teams.create_member(team.id, %{
          "name" => name,
          "role" => role,
          "duty" => "#{role} 的职责",
          "agent_kind" => "claude",
          "agent_args" => "--allowedTools 'Bash(git:*)' --model opus"
        })
    end

    start(%{task | team_id: team.id})

    assert_receive {:herdr, {:agent_command, name, "claude", args}}
    assert name == "#{task.id}-cc"
    assert args == ["--allowedTools", "Bash(git:*)", "--model", "opus"]
    assert_receive {:herdr, {:prompt, ^name, prompt}}
    assert prompt =~ "你的职责：coder 的职责"
    assert prompt =~ "按 #{Step.task_dir(task)}/plan.md 实现"
    settle(task.id)
  end

  test "queued tasks start as their team frees up", %{task: task} do
    {:ok, team} =
      task.project_id |> Teams.default_team() |> Teams.update_team(%{"max_concurrent_tasks" => 1})

    queue = fn title ->
      {:ok, t} =
        Tasks.save_task(
          Runner.enqueue(%{task | id: "t-#{title}", title: title, team_id: team.id})
        )

      t
    end

    first = queue.("q1")
    second = queue.("q2")

    assert %{id: id} = await_task(&(&1.id == first.id and not &1.queued))
    assert id == first.id
    assert_receive {:herdr, {:prompt, _, _}}
    assert Tasks.get_task(second.id).queued

    {:ok, _} = Tasks.save_task(Runner.cancel(Tasks.get_task(first.id), DateTime.utc_now()))
    await_task(&(&1.id == second.id and not &1.queued))
    assert_receive {:herdr, {:prompt, _, _}}
    settle(second.id)
  end

  defp settle(task_id) do
    _ = :sys.get_state(HerdrLiveView.Engine.TaskWorker.via(task_id))
    _ = :sys.get_state(HerdrLiveView.Engine.Manager)
  end
end
