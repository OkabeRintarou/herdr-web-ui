defmodule HerdrLiveView.Engine.TaskWorker do
  @moduledoc """
  Drives one herdr-executed task: for each step visit it makes sure the role's agent exists,
  sends the step prompt, watches the agent's status and applies the verdict from the result file.
  """
  use GenServer, restart: :transient
  require Logger

  alias HerdrLiveView.Engine.{Herdr, Step}
  alias HerdrLiveView.Herdr.Panes
  alias HerdrLiveView.{Projects, Tasks, Teams}
  alias HerdrLiveView.Tasks.Runner

  @tick_ms 5_000

  def start_link(task_id),
    do: GenServer.start_link(__MODULE__, task_id, name: via(task_id))

  def via(task_id), do: {:via, Registry, {HerdrLiveView.Engine.Registry, task_id}}

  @impl true
  def init(task_id) do
    # finish the current message (often a DB write) before honouring a shutdown
    Process.flag(:trap_exit, true)
    Tasks.subscribe()
    send(self(), :sync)
    schedule_tick()

    {:ok,
     %{
       task_id: task_id,
       task: nil,
       host: nil,
       team: nil,
       dispatched: nil,
       saw_working: false,
       nudged: false,
       dispatched_at: nil,
       last_status: nil,
       # consecutive dispatches parked on an agent dialog; stops auto-retrying after 3
       failures: 0
     }}
  end

  @impl true
  def handle_info(:sync, state) do
    with %{} = task <- Tasks.get_task(state.task_id),
         %{host: host} <- task.project_id && Projects.get_project(task.project_id) do
      Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic(host.id))
      state = %{state | host: host, team: Teams.get_team(task.team_id)}
      handle_task(task, recover(task, state))
    else
      _ -> {:stop, :normal, state}
    end
  end

  # :sync hasn't loaded the host yet; it reads the latest task itself.
  def handle_info({:task_saved, _task}, %{host: nil} = state), do: {:noreply, state}

  def handle_info({:task_saved, %{id: id} = task}, %{task_id: id} = state),
    do: handle_task(task, state)

  def handle_info({:task_saved, _other}, state), do: {:noreply, state}

  def handle_info({:herdr_panes, _status, panes}, state) do
    {:noreply, see(state, get_in(panes, [state.task && state.task.pane_id, "agent_status"]))}
  end

  # Also samples the status itself: pane broadcasts only fire on change and may predate us.
  def handle_info(:tick, %{host: nil} = state) do
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    panes = Herdr.impl().panes(state.host)
    status = get_in(panes, [state.task && state.task.pane_id, "agent_status"])
    {:noreply, state |> see(status) |> check_result(:tick)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp see(state, status) do
    seen = {state.task && state.task.pane_id, status}
    if seen == state.last_status, do: state, else: observe(%{state | last_status: seen}, status)
  end

  # After a restart, don't re-send a prompt the agent already received.
  defp recover(task, state) do
    with %{role: role} <- Runner.current_step(task),
         %{"step" => key} <- task.agents[role],
         true <- key == Step.key(task) do
      %{
        state
        | dispatched: key,
          saw_working: true,
          dispatched_at: System.monotonic_time(:millisecond)
      }
    else
      _ -> state
    end
  end

  defp handle_task(task, state) do
    state = %{state | task: task}

    cond do
      task.stage == :done ->
        {:stop, :normal, state}

      not active?(task) ->
        # a human resumed the task after we escalated: allow one more nudge
        {:noreply, if(task.attention, do: state, else: %{state | nudged: false})}

      Step.key(task) != state.dispatched ->
        {:noreply, dispatch(state)}

      true ->
        {:noreply, state}
    end
  end

  defp active?(task) do
    task.stage in [:plan, :implement] and is_nil(task.attention) and not task.paused and
      Runner.agent_step?(task)
  end

  defp dispatch(%{task: task, host: host} = state) do
    role = Runner.current_step(task).role
    File.mkdir_p!(Step.task_dir(task))
    # re-read so edits to the team's member templates apply to the next agent we start
    state = %{state | team: Teams.get_team(task.team_id)}

    with {:ok, task, agent} <- ensure_agent(host, state.team, task, role) do
      task = %{task | pane_id: agent["pane_id"]}

      prompt = Step.prompt(task, Teams.member_for(state.team, role))

      case Herdr.impl().prompt(host, agent["name"], prompt) do
        :ok ->
          agents = Map.put(task.agents, role, Map.put(agent, "step", Step.key(task)))
          {:ok, task} = Tasks.save_task(%{task | agents: agents, agent_status: "working"})

          %{
            state
            | task: task,
              dispatched: Step.key(task),
              saw_working: false,
              nudged: false,
              failures: 0,
              dispatched_at: System.monotonic_time(:millisecond)
          }

        # e.g. the agent's first-run folder-trust dialog; lifted in observe/2 once it moves on
        {:error, {:herdr, %{"code" => code}}}
        when code in ["agent_blocked", "agent_not_ready"] and state.failures < 3 ->
          message = "#{role} 在 #{task.pane_id} 上等待确认（如信任目录），处理后会自动继续"
          {:ok, task} = Tasks.save_task(Runner.block(task, message, "agent_blocked"))
          %{state | task: task, failures: state.failures + 1}

        {:error, reason} ->
          dispatch_failed(%{state | task: task}, role, reason)
      end
    else
      {:error, reason} -> dispatch_failed(state, role, reason)
    end
  end

  defp dispatch_failed(%{task: task} = state, role, reason) do
    Logger.warning("task #{task.id}: dispatch failed: #{inspect(reason)}")
    # ensure_agent may already have stored a new pane; don't overwrite it
    state = %{state | task: Tasks.get_task(task.id) || task, failures: 0}
    escalate(state, "无法启动 #{role} 或发送指令：#{format(reason)}")
  end

  defp ensure_agent(host, team, task, role) do
    member = Teams.member_for(team, role)

    name =
      get_in(task.agents, [role, "name"]) || agent_name(task, (member && member.name) || role)

    spec = agent_command(member)

    case Herdr.impl().find_agent(host, name) do
      {:ok, pane} ->
        adopt(task, role, name, pane)

      :error ->
        panes = Herdr.impl().panes(host)

        case get_in(task.agents, [role, "pane_id"]) do
          pane when is_map_key(panes, pane) ->
            start_agent(host, spec, task, role, pane, name)

          _ ->
            with {:ok, task, pane} <- open_pane(host, task, panes) do
              agents = Map.put(task.agents, role, %{"name" => name, "pane_id" => pane})
              {:ok, task} = Tasks.save_task(%{task | agents: agents, pane_id: pane})
              start_agent(host, spec, task, role, pane, name)
            end
        end
    end
  end

  defp adopt(task, role, name, pane) do
    agent = Map.merge(task.agents[role] || %{}, %{"name" => name, "pane_id" => pane})
    {:ok, %{task | agents: Map.put(task.agents, role, agent)}, agent}
  end

  defp open_pane(host, task, panes) do
    cwd = task.workdir

    sibling =
      Enum.find_value(task.agents, fn {_role, %{"pane_id" => pane}} ->
        if Map.has_key?(panes, pane), do: pane
      end)

    if sibling do
      with {:ok, pane} <- Herdr.impl().split_pane(host, sibling, cwd), do: {:ok, task, pane}
    else
      with {:ok, ws, pane} <- Herdr.impl().create_workspace(host, cwd, "task #{task.id}") do
        {:ok, %{task | workspace_id: ws}, pane}
      end
    end
  end

  defp start_agent(host, {kind, args} = spec, task, role, pane, name, attempts \\ 10) do
    case Herdr.impl().start_agent(host, name, kind, pane, args) do
      :ok ->
        adopt(task, role, name, pane)

      # a freshly opened pane needs a moment before its shell prompt is ready
      {:error, {:herdr, %{"code" => "agent_pane_busy"}}} when attempts > 1 ->
        Process.sleep(1_000)
        start_agent(host, spec, task, role, pane, name, attempts - 1)

      # the agent launched but stopped at its own startup dialog; prompting will surface that
      {:error, {:herdr, %{"code" => code}}} = error
      when code in ["agent_not_ready", "agent_name_taken"] ->
        case Herdr.impl().find_agent(host, name) do
          {:ok, actual} -> adopt(task, role, name, actual)
          :error -> error
        end

      error ->
        error
    end
  end

  # The user answered the agent directly in herdr, so the block we raised no longer applies.
  defp observe(%{task: %{attention: %{key: "agent_blocked"}} = task} = state, status)
       when status in ["working", "idle", "done"] do
    {:ok, task} = Tasks.save_task(Runner.resume(task))
    %{state | task: task, saw_working: status == "working"}
  end

  defp observe(%{dispatched: nil} = state, _status), do: state

  defp observe(state, "working"), do: %{state | saw_working: true}

  defp observe(%{task: task} = state, "blocked") do
    if active?(task) do
      message = "#{task.pane_id} 上的 agent 在等待审批或回答问题"
      {:ok, task} = Tasks.save_task(Runner.block(task, message, "agent_blocked"))
      %{state | task: task}
    else
      state
    end
  end

  defp observe(state, status) when status in ["idle", "done"], do: check_result(state, :idle)
  defp observe(state, _status), do: state

  defp check_result(%{dispatched: nil} = state, _reason), do: state

  defp check_result(%{task: task} = state, reason) do
    if active?(task) and Step.key(task) == state.dispatched do
      case Step.read_result(task) do
        {:ok, verdict, summary} ->
          {:ok, task} =
            Tasks.save_task(Runner.verdict(task, verdict, summary, DateTime.utc_now()))

          %{state | task: task}

        :missing when reason == :idle ->
          if state.saw_working or elapsed(state) > 30_000,
            do: nudge(state, "你还没有写结果文件 #{Step.result_path(task)}。"),
            else: state

        {:invalid, why} when reason == :idle ->
          nudge(state, "结果文件 #{Step.result_path(task)} 不符合要求：#{why}。")

        _ ->
          check_timeout(state)
      end
    else
      state
    end
  end

  defp nudge(%{nudged: false, task: task} = state, problem) do
    text = problem <> "请按之前的要求写入 JSON 结果文件后结束本轮。"
    target = task.agents[Runner.current_step(task).role]["name"]

    case Herdr.impl().prompt(state.host, target, text) do
      :ok ->
        %{
          state
          | nudged: true,
            saw_working: false,
            dispatched_at: System.monotonic_time(:millisecond)
        }

      {:error, reason} ->
        escalate(state, "提醒 agent 失败：#{format(reason)}")
    end
  end

  defp nudge(state, problem), do: escalate(state, "agent 停下了但仍未交付结果：" <> problem)

  defp check_timeout(state) do
    limit =
      if state.team,
        do: state.team.step_timeout_min * 60_000,
        else: Application.get_env(:herdr_liveview, :step_timeout_ms, 60 * 60_000)

    if elapsed(state) > limit,
      do: escalate(state, "本步超过 #{div(limit, 60_000)} 分钟仍未完成"),
      else: state
  end

  defp elapsed(state), do: System.monotonic_time(:millisecond) - state.dispatched_at

  defp escalate(%{task: task} = state, message) do
    {:ok, task} = Tasks.save_task(Runner.block(task, message))
    %{state | task: task}
  end

  # Tasks without a team (from before teams existed) fall back to the configured agent CLI.
  defp agent_command(nil) do
    {Application.get_env(:herdr_liveview, :agent_kind, "copilot"),
     Application.get_env(:herdr_liveview, :agent_args, [])}
  end

  defp agent_command(member), do: {member.agent_kind, OptionParser.split(member.agent_args)}

  # herdr agent names: [a-z][a-z0-9_-]{0,31}
  defp agent_name(task, role) do
    "#{task.id}-#{role}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.slice(0, 32)
  end

  defp format({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
  defp format(reason), do: inspect(reason)

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
