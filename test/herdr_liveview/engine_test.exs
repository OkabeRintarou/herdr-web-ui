defmodule HerdrLiveView.EngineTest do
  use HerdrLiveView.DataCase, async: false

  import HerdrLiveView.Fixtures

  alias HerdrLiveView.{Engine, FakeHerdr, Tasks}
  alias HerdrLiveView.Engine.Step
  alias HerdrLiveView.Tasks.Runner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
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

    %{task: task}
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

  test "simulated tasks are never picked up", %{task: task} do
    start(%{task | executor: "simulated"})
    refute_receive {:herdr, _}, 200
  end
end
