defmodule HerdrLiveView.Engine.TaskWorker do
  @moduledoc """
  Drives one herdr-executed task: for each step visit it makes sure the role's agent exists,
  sends the step prompt, watches the agent's status and applies the verdict from the result file.
  """
  use GenServer, restart: :transient
  require Logger

  alias HerdrLiveView.Engine.{Agents, Design, Herdr, Step}
  alias HerdrLiveView.Herdr.Panes
  alias HerdrLiveView.Hosts.Shell
  alias HerdrLiveView.{Projects, Tasks, Teams, Worktrees}
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
       project: nil,
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
         %{host: host} = project <- task.project_id && Projects.get_project(task.project_id) do
      Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic(host.id))
      state = %{state | project: project, host: host, team: Teams.get_team(task.team_id)}
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
        {:stop, :normal, release_all(state)}

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

  defp dispatch(%{task: task} = state) do
    case Worktrees.ensure(state.project, task) do
      {:ok, ^task} ->
        send_step(state)

      {:ok, task} ->
        {:ok, task} = Tasks.save_task(task)
        send_step(%{state | task: task})

      {:error, reason} ->
        escalate(state, "无法创建 worktree：#{reason}")
    end
  end

  defp send_step(%{task: task, host: host} = state) do
    role = Runner.current_step(task).role
    Shell.mkdir_p!(host, Step.task_dir(task))
    # re-read so edits to the team's member templates apply to the next agent we start
    state = %{state | team: Teams.get_team(task.team_id)}

    with {:ok, task, agent} <- ensure_agent(host, state.team, task, role) do
      task = %{task | pane_id: agent["pane_id"]}
      now = DateTime.utc_now()

      body =
        if task.step == "design",
          do: Design.prompt(task, state.team),
          else: Step.prompt(task, member(state.team, task, role))

      intro =
        if (agent["uses"] || 0) == 0,
          do: Agents.handoff(task, agent),
          else: Agents.wake_up(host, task, agent, now)

      case Herdr.impl().prompt(host, agent["name"], intro <> body) do
        :ok ->
          agents = Map.put(task.agents, role, Agents.used(host, agent, task, now))
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
    member = member(team, task, role)
    member_name = (member && member.name) || role
    spec = agent_command(member)

    task =
      if Agents.replace?(task.agents[role], member_name),
        do: recycle(host, task, role),
        else: task

    current = task.agents[role]

    name =
      if Agents.live?(current),
        do: current["name"],
        else: Agents.instance_name(task, member_name, Agents.next_n(current))

    case Herdr.impl().find_agent(host, name) do
      {:ok, pane} ->
        adopt(task, role, name, pane, member_name)

      :error ->
        # a recorded instance that is gone (closed by hand, evicted) gets a successor
        {task, name} =
          if Agents.live?(current) do
            task = %{task | agents: Map.put(task.agents, role, Agents.recycled(current))}
            {task, Agents.instance_name(task, member_name, Agents.next_n(task.agents[role]))}
          else
            {task, name}
          end

        with {:ok, task} <- make_room(host, task, role) do
          panes = Herdr.impl().panes(host)
          # the old instance's pane is reused when its agent exited back to the shell
          old = current && current["pane_id"]

          if is_map_key(panes, old) and is_nil(panes[old]["agent"]) do
            start_agent(host, spec, task, role, old, name, member_name)
          else
            with {:ok, task, pane} <- open_pane(host, task, panes) do
              n = Agents.next_n(task.agents[role])
              entry = %{"name" => name, "pane_id" => pane, "member" => member_name, "n" => n}
              agents = Map.put(task.agents, role, entry)
              {:ok, task} = Tasks.save_task(%{task | agents: agents, pane_id: pane})
              start_agent(host, spec, task, role, pane, name, member_name)
            end
          end
        end
    end
  end

  defp adopt(task, role, name, pane, member_name) do
    previous = task.agents[role] || %{}

    n =
      if Agents.live?(previous) and previous["name"] == name,
        do: previous["n"] || 1,
        else: Agents.next_n(previous)

    agent =
      if previous["name"] == name,
        do: Map.merge(previous, %{"pane_id" => pane}),
        else: %{"name" => name, "pane_id" => pane, "member" => member_name, "n" => n}

    {:ok, %{task | agents: Map.put(task.agents, role, agent)}, agent}
  end

  # Looked up by name, so a stale pane id never closes someone else's pane.
  defp recycle(host, task, role) do
    agent = task.agents[role]

    with true <- Agents.live?(agent),
         {:ok, pane} <- Herdr.impl().find_agent(host, agent["name"]),
         do: Herdr.impl().close_pane(host, pane)

    %{task | agents: Map.put(task.agents, role, Agents.recycled(agent))}
  end

  defp release_all(%{task: task, host: host} = state) do
    if Enum.any?(task.agents, fn {_role, agent} -> Agents.live?(agent) end) do
      task = Enum.reduce(Map.keys(task.agents), task, &recycle(host, &2, &1))
      {:ok, task} = Tasks.save_task(task)
      %{state | task: task}
    else
      state
    end
  end

  # Keeps the host under its agent limit by closing the least recently used idle instance.
  defp make_room(host, task, role) do
    panes = Herdr.impl().panes(host)
    ours = for {pane, %{"name" => "t-" <> _}} <- panes, do: pane

    if length(ours) < host.max_agents do
      {:ok, task}
    else
      on_host = for p <- Projects.list_projects(), p.host_id == host.id, do: p.id

      candidates =
        for t <- [task | Enum.reject(Tasks.list_tasks(), &(&1.id == task.id))],
            t.executor == "herdr" and t.project_id in on_host,
            {r, agent} <- t.agents,
            Agents.live?(agent) and get_in(panes, [agent["pane_id"], "name"]) == agent["name"],
            not (t.id == task.id and r == role),
            not busy?(t, r),
            do: {t, r, agent}

      case Enum.min_by(candidates, fn {_t, _r, a} -> a["last_used"] || 0 end, fn -> nil end) do
        nil ->
          {:error, {:host_full, host.max_agents}}

        {t, r, agent} ->
          Logger.info("evicting #{agent["name"]} to make room on #{host.name}")
          Herdr.impl().close_pane(host, agent["pane_id"])

          # other tasks notice the instance is gone when they next need it
          if t.id == task.id,
            do: {:ok, %{task | agents: Map.put(task.agents, r, Agents.recycled(agent))}},
            else: {:ok, task}
      end
    end
  end

  defp busy?(task, role) do
    task.stage in [:plan, :implement] and is_nil(task.attention) and
      match?(%{role: ^role}, Runner.current_step(task))
  end

  defp open_pane(host, task, panes) do
    cwd = task.workdir

    sibling =
      Enum.find_value(task.agents, fn
        {_role, %{"pane_id" => pane}} -> if Map.has_key?(panes, pane), do: pane
        _recycled -> nil
      end)

    if sibling do
      with {:ok, pane} <- Herdr.impl().split_pane(host, sibling, cwd), do: {:ok, task, pane}
    else
      with {:ok, ws, pane} <- Herdr.impl().create_workspace(host, cwd, "task #{task.id}") do
        {:ok, %{task | workspace_id: ws}, pane}
      end
    end
  end

  defp start_agent(host, {kind, args} = spec, task, role, pane, name, member, attempts \\ 10) do
    case Herdr.impl().start_agent(host, name, kind, pane, args) do
      :ok ->
        adopt(task, role, name, pane, member)

      # a freshly opened pane needs a moment before its shell prompt is ready
      {:error, {:herdr, %{"code" => "agent_pane_busy"}}} when attempts > 1 ->
        Process.sleep(1_000)
        start_agent(host, spec, task, role, pane, name, member, attempts - 1)

      # the agent launched but stopped at its own startup dialog; prompting will surface that
      {:error, {:herdr, %{"code" => code}}} = error
      when code in ["agent_not_ready", "agent_name_taken"] ->
        case Herdr.impl().find_agent(host, name) do
          {:ok, actual} -> adopt(task, role, name, actual, member)
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

  defp member(team, task, role),
    do: Teams.member_for(team, role, task.workflow && Map.get(task.workflow, :assignments))

  defp check_result(%{dispatched: nil} = state, _reason), do: state

  defp check_result(%{task: task} = state, reason) do
    if active?(task) and Step.key(task) == state.dispatched do
      case read_result(state) do
        {:ok, verdict, summary} ->
          role = Runner.current_step(task).role

          task =
            task
            |> Runner.verdict(verdict, summary, DateTime.utc_now())
            |> after_verdict(state, role, verdict)

          {:ok, task} = Tasks.save_task(task)
          %{state | task: task}

        {:ok, workflow} ->
          {:ok, task} = Tasks.save_task(Runner.propose(task, workflow, DateTime.utc_now()))
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

  # A replan starts everyone fresh; an ephemeral member's instance goes once its step is done.
  defp after_verdict(task, state, role, verdict) do
    cond do
      verdict == "needs_replan" ->
        %{task | agents: Agents.retire_all(task.agents)}

      match?(%{lifetime: "ephemeral"}, member(state.team, task, role)) ->
        recycle(state.host, task, role)

      true ->
        task
    end
  end

  defp read_result(%{task: %{step: "design"} = task, team: team, host: host}),
    do: Design.read_plan(task, team, host)

  defp read_result(%{task: task, host: host}), do: Step.read_result(task, host)

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

  defp format({:host_full, max}), do: "主机上的 agent 已达上限 #{max} 个，且都在忙"
  defp format({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
  defp format(reason), do: inspect(reason)

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
