defmodule HerdrLiveViewWeb.TaskBoardLive do
  use HerdrLiveViewWeb, :live_view

  import HerdrLiveViewWeb.WorkflowGraph, only: [graph: 1]

  alias HerdrLiveView.Herdr.Panes
  alias HerdrLiveView.{Tasks, Teams, Worktrees}
  alias HerdrLiveView.Tasks.{Demo, Runner, Workflow}
  alias HerdrLiveViewWeb.LiveTerminal

  @lead_delay_ms 2_500

  @columns %{
    todo: %{label: "待办", icon: "hero-inbox-micro", accent: "text-zinc-400"},
    plan: %{label: "规划", icon: "hero-light-bulb-micro", accent: "text-violet-300"},
    implement: %{label: "实现", icon: "hero-code-bracket-micro", accent: "text-sky-300"},
    attention: %{label: "待人处理", icon: "hero-hand-raised-micro", accent: "text-amber-300"},
    done: %{label: "完成", icon: "hero-check-circle-micro", accent: "text-emerald-300"}
  }

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case HerdrLiveView.Projects.get_by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "项目 #{slug} 不存在") |> push_navigate(to: ~p"/")}

      project ->
        {:ok, mount_project(socket, project)}
    end
  end

  defp mount_project(socket, project) do
    host = project.host

    if connected?(socket) do
      Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic(host.id))
      Tasks.subscribe()
    end

    {status, panes} = Panes.snapshot(host.id)

    socket =
      Enum.reduce(Demo.stages(), socket, fn stage, socket ->
        stream_configure(socket, stage, dom_id: &"task-#{&1.id}")
      end)

    socket
    |> assign(project: project, host: host, status: status, panes: panes, stages: Demo.stages())
    |> assign_teams()
    |> assign(tasks: Map.new(Tasks.list_tasks(project.id), &{&1.id, &1}), task: nil)
    |> then(&assign(&1, form: new_task_form(&1), comment_form: comment_form()))
    |> LiveTerminal.init()
    |> stream_columns()
  end

  defp assign_teams(socket) do
    teams = Teams.list_teams(socket.assigns.project.id)
    assign(socket, teams: teams, team_names: Map.new(teams, &{&1.id, &1.name}))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case socket.assigns.tasks[id] do
      nil ->
        socket
        |> put_flash(:error, "Task #{id} 不存在")
        |> push_patch(to: ~p"/p/#{socket.assigns.project.slug}")

      task ->
        socket
        |> assign(task: task, page_title: task.title, comment_form: comment_form())
        |> LiveTerminal.watch(live_pane(socket.assigns.panes, task))
    end
  end

  defp apply_action(socket, :new, _params) do
    socket = assign_teams(socket)

    socket
    |> assign(task: nil, page_title: "新建 Task", form: new_task_form(socket))
    |> LiveTerminal.watch(nil)
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(task: nil, page_title: "看板") |> LiveTerminal.watch(nil)
  end

  @impl true
  def handle_info({:herdr_panes, status, panes}, socket) do
    socket = assign(socket, status: status, panes: panes)

    socket =
      if task = socket.assigns.task,
        do: LiveTerminal.watch(socket, live_pane(panes, task)),
        else: socket

    {:noreply, socket}
  end

  def handle_info(:terminal_poll, socket), do: {:noreply, LiveTerminal.handle_poll(socket)}

  def handle_info({:task_saved, %{project_id: project_id} = task}, socket)
      when project_id == socket.assigns.project.id,
      do: {:noreply, apply_task(socket, task)}

  def handle_info({:task_saved, _other_project}, socket), do: {:noreply, socket}

  def handle_info({:lead_proposal, id, version, feedback}, socket) do
    case socket.assigns.tasks[id] do
      %{step: "design"} = task ->
        workflow = Workflow.propose(task, version, feedback)

        {:noreply,
         put_task(socket, Runner.propose(task, workflow, now()), "lead 提交了流程 v#{version}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/p/#{socket.assigns.project.slug}")}

  def handle_event("validate", %{"task" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :task, errors: validate(params, socket)))}
  end

  def handle_event("create", %{"task" => params}, socket) do
    project = socket.assigns.project

    case validate(params, socket) do
      [] ->
        team = team_of(socket.assigns.teams, %{team_id: params["team_id"]})

        task =
          params
          |> Map.merge(%{
            "project_id" => project.id,
            "workdir" => project.path,
            "template" => Teams.workflow(team, params["workflow"])
          })
          |> Runner.new()

        {:noreply,
         socket
         |> put_task(task, "已创建")
         |> push_patch(to: ~p"/p/#{project.slug}/tasks/#{task.id}")}

      errors ->
        {:noreply, assign(socket, form: to_form(params, as: :task, errors: errors))}
    end
  end

  # Real tasks wait for a free slot in their team; the engine's scheduler starts them.
  def handle_event("start", %{"id" => id}, socket) do
    with_task(socket, id, fn
      %{executor: "herdr", team_id: team_id} = task when is_binary(team_id) ->
        {Runner.enqueue(task), "已加入 #{socket.assigns.team_names[team_id]} 的队列"}

      task ->
        task = Runner.start(task, now())

        if task.step == "design" and task.executor == "simulated",
          do: schedule_lead(task, 1, nil)

        {task, if(task.step == "design", do: "lead 正在设计流程…", else: "已开始")}
    end)
  end

  def handle_event("approve_workflow", %{"id" => id}, socket) do
    with_task(socket, id, &{Runner.approve_workflow(&1, now()), "流程已批准，开工"})
  end

  def handle_event("redesign", %{"task_id" => id, "comment" => %{"text" => text}}, socket) do
    with_task(socket, id, fn task ->
      version = task.proposal.workflow.version + 1
      feedback = blank_to_nil(text)
      if task.executor == "simulated", do: schedule_lead(task, version, feedback)
      {Runner.redesign(task, now(), feedback), "已让 lead 重新设计"}
    end)
  end

  def handle_event("save_template", %{"id" => id}, socket) do
    task = socket.assigns.tasks[id]
    workflow = %{task.workflow | id: "from-#{task.id}"}

    socket =
      case Teams.save_workflow(task.team_id, workflow) do
        {:ok, _} ->
          socket
          |> assign_teams()
          |> put_flash(
            :info,
            "已存为 #{socket.assigns.team_names[task.team_id]} 的模板「#{workflow.name}」"
          )

        {:error, _} ->
          put_flash(socket, :error, "这个流程已经存过了")
      end

    {:noreply, socket}
  end

  def handle_event("cleanup_worktree", %{"id" => id}, socket) do
    with_task(socket, id, fn task ->
      case Worktrees.remove(socket.assigns.project, task) do
        {:ok, task} -> {task, "worktree 已清理，分支 #{task.branch} 保留"}
        {:error, reason} -> {task, "清理失败：#{reason}"}
      end
    end)
  end

  def handle_event("use_template", %{"id" => id, "template" => key}, socket) do
    with_task(socket, id, fn task ->
      case Teams.workflow(team_of(socket.assigns.teams, task), key) do
        nil -> {task, "Team 里没有这个流程"}
        template -> {Runner.use_template(task, template, now()), "已改用模板"}
      end
    end)
  end

  def handle_event("verdict", %{"id" => id, "verdict" => verdict}, socket) do
    with_task(socket, id, fn task ->
      label = Runner.current_step(task).label
      {Runner.verdict(task, verdict, nil, now()), "#{label}：#{Workflow.verdict_label(verdict)}"}
    end)
  end

  def handle_event("send_back", %{"task_id" => id, "comment" => %{"text" => text}}, socket) do
    with_task(socket, id, fn task ->
      {Runner.verdict(task, "reject", blank_to_nil(text), now()), "已退回"}
    end)
  end

  def handle_event("extend", %{"id" => id}, socket) do
    with_task(socket, id, &{Runner.extend(&1, now()), "已放行一轮"})
  end

  def handle_event("jump", %{"id" => id, "step" => step}, socket) do
    with_task(socket, id, &{Runner.jump(&1, step, now()), "已退回到指定步骤"})
  end

  def handle_event("resume", %{"id" => id}, socket) do
    with_task(socket, id, &{Runner.resume(&1), "已批准，agent 继续"})
  end

  def handle_event("toggle_pause", %{"id" => id}, socket) do
    with_task(socket, id, &{Runner.toggle_pause(&1), nil})
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    with_task(socket, id, &{Runner.cancel(&1, now()), "已取消"})
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, columns: @columns)

    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <:crumb>
        <span class="truncate font-medium text-zinc-200">{@project.name}</span>
        <span class="truncate font-mono text-xs text-zinc-500">{@host.name}:{@project.path}</span>
        <.link
          id="project-settings"
          navigate={~p"/p/#{@project.slug}/settings"}
          class="rounded-md p-1 text-zinc-500 transition hover:bg-white/5 hover:text-zinc-200"
          title="项目设置"
        >
          <.icon name="hero-cog-6-tooth-micro" class="size-4" />
        </.link>
      </:crumb>
      <:status>
        <span
          id="attention-count"
          class={[
            "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs ring-1",
            if(count(@tasks, :attention) > 0,
              do: "bg-amber-400/10 text-amber-300 ring-amber-400/30",
              else: "bg-white/5 text-zinc-500 ring-white/10"
            )
          ]}
        >
          <.icon name="hero-bell-micro" class="size-3.5" /> {count(@tasks, :attention)}
        </span>
        <.connection status={@status} />
        <.link
          id="new-task"
          patch={~p"/p/#{@project.slug}/new"}
          class="inline-flex items-center gap-1 rounded-lg bg-emerald-500 px-2 py-1.5 text-xs font-medium whitespace-nowrap text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98] sm:px-3"
        >
          <.icon name="hero-plus-micro" class="size-4" />
          <span class="hidden sm:inline">新建 Task</span>
        </.link>
      </:status>

      <div class="flex h-full snap-x snap-mandatory gap-3 overflow-x-auto p-4 sm:snap-none">
        <section
          :for={stage <- @stages}
          id={"col-#{stage}"}
          class={[
            "flex w-[85vw] shrink-0 snap-start flex-col rounded-2xl ring-1 sm:w-72 xl:w-auto xl:min-w-64 xl:flex-1 xl:shrink",
            if(stage == :attention,
              do: "bg-amber-400/[0.03] ring-amber-400/15",
              else: "bg-zinc-900/40 ring-white/5"
            )
          ]}
        >
          <header class="flex items-center justify-between px-3 pt-3 pb-2">
            <h2 class={["flex items-center gap-1.5 text-xs font-medium", @columns[stage].accent]}>
              <.icon name={@columns[stage].icon} class="size-4" />
              {@columns[stage].label}
            </h2>
            <span class="rounded-full bg-white/5 px-2 py-0.5 text-[11px] text-zinc-400">
              {count(@tasks, stage)}
            </span>
          </header>

          <div
            id={"col-#{stage}-cards"}
            phx-update="stream"
            class="flex-1 space-y-2 overflow-y-auto px-2 pb-3"
          >
            <p
              id={"col-#{stage}-empty"}
              class="hidden rounded-xl border border-dashed border-white/5 px-3 py-6 text-center text-xs text-zinc-600 only:block"
            >
              暂无 task
            </p>
            <.task_card
              :for={{dom_id, task} <- Map.fetch!(@streams, stage)}
              id={dom_id}
              task={task}
              slug={@project.slug}
              team_name={@team_names[task.team_id]}
              agent_status={agent_status(@panes, task)}
            />
          </div>
        </section>
      </div>

      <.task_drawer
        :if={@live_action == :show and @task}
        task={@task}
        templates={Teams.workflows(team_of(@teams, @task))}
        panes={@panes}
        host_id={@host.id}
        live_pane={live_pane(@panes, @task)}
        comment_form={@comment_form}
      />

      <.new_task_modal
        :if={@live_action == :new}
        form={@form}
        teams={@teams}
      />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :task, :map, required: true
  attr :slug, :string, required: true
  attr :team_name, :string, default: nil
  attr :agent_status, :string, default: nil

  defp task_card(assigns) do
    assigns = assign(assigns, step: Runner.current_step(assigns.task))

    ~H"""
    <.link
      id={@id}
      patch={~p"/p/#{@slug}/tasks/#{@task.id}"}
      class={[
        "group block rounded-xl bg-zinc-900 p-3 ring-1 transition duration-150 hover:-translate-y-px hover:bg-zinc-800/80 hover:shadow-lg hover:shadow-black/30",
        cond do
          @task.stage == :attention -> "ring-amber-400/30"
          overdue?(@task) -> "ring-rose-400/30"
          true -> "ring-white/5 hover:ring-white/10"
        end,
        @task.cancelled && "opacity-50"
      ]}
    >
      <div class="flex items-center gap-2">
        <.priority priority={@task.priority} />
        <span class="font-mono text-[11px] text-zinc-600">{@task.id}</span>
        <span
          :if={@task.executor == "simulated"}
          class="rounded bg-violet-400/10 px-1 text-[10px] text-violet-300"
        >
          模拟
        </span>
        <span class="ml-auto truncate text-[11px] text-zinc-500">
          <span :if={@team_name} class="text-zinc-400">{@team_name} · </span>{workflow_badge(@task)}
        </span>
      </div>

      <p class="mt-1.5 line-clamp-2 text-sm leading-snug font-medium text-zinc-100">
        {@task.title}
      </p>

      <p
        :if={@task.queued}
        class="mt-2 inline-flex items-center gap-1 rounded-md bg-white/5 px-2 py-1 text-xs text-zinc-400"
      >
        <.icon name="hero-queue-list-micro" class="size-3.5" /> 排队中，等 Team 有空位
      </p>

      <p
        :if={@task.attention}
        class="mt-2 line-clamp-2 rounded-md bg-amber-400/10 px-2 py-1.5 text-xs leading-snug text-amber-200/90"
      >
        {@task.attention.message}
      </p>
      <p
        :if={!@task.attention && @task.last_bounce && @task.stage in [:plan, :implement]}
        class="mt-2 flex items-center gap-1 text-xs text-amber-300/80"
      >
        <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> {@task.last_bounce}
      </p>

      <div class="mt-2.5 flex items-center gap-2 text-[11px] text-zinc-500">
        <span
          :if={@step && @task.stage != :done}
          class="inline-flex min-w-0 items-center gap-1.5 text-zinc-300"
        >
          <.agent_dot status={@agent_status} />
          <span class="truncate">{@step.label} · {@step.role}</span>
        </span>
        <span
          :if={@step && Map.get(@task.visits, @step.id, 0) > 1}
          class="shrink-0 rounded bg-white/5 px-1.5 py-0.5 text-zinc-400"
        >
          第 {@task.visits[@step.id]} 轮
        </span>
        <span :if={@task.paused} class="inline-flex shrink-0 items-center gap-0.5 text-zinc-400">
          <.icon name="hero-pause-micro" class="size-3" /> 暂停
        </span>
        <span :if={@task.cancelled} class="text-zinc-500">已取消</span>
        <span class={[
          "ml-auto inline-flex shrink-0 items-center gap-1",
          overdue?(@task) && "text-rose-300"
        ]}>
          <.icon name="hero-clock-micro" class="size-3" />
          {elapsed(@task.stage_since)}
        </span>
      </div>
    </.link>
    """
  end

  attr :task, :map, required: true
  attr :templates, :list, required: true
  attr :panes, :map, required: true
  attr :host_id, :string, required: true
  attr :live_pane, :string, default: nil
  attr :comment_form, :any, required: true

  defp task_drawer(assigns) do
    assigns = assign(assigns, step: Runner.current_step(assigns.task))

    ~H"""
    <div id="task-drawer" class="fixed inset-0 z-40" phx-window-keydown="close" phx-key="Escape">
      <button
        type="button"
        phx-click="close"
        aria-label="关闭"
        class="absolute inset-0 cursor-default bg-black/50 backdrop-blur-[2px]"
      />
      <aside class="absolute inset-y-0 right-0 flex w-full max-w-6xl flex-col border-l border-white/10 bg-zinc-950 shadow-2xl shadow-black/60">
        <header class="flex items-start justify-between gap-4 border-b border-white/5 px-5 py-4">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <.priority priority={@task.priority} />
              <span class="font-mono text-zinc-500">{@task.id}</span>
              <span class="text-zinc-500">· {workflow_badge(@task)}</span>
              <span :if={@step} class="text-zinc-300">· {@step.label}</span>
              <span
                :if={@task.executor == "simulated"}
                class="rounded bg-violet-400/10 px-1.5 text-violet-300"
              >
                模拟执行
              </span>
            </div>
            <h2 class="mt-1 truncate text-lg font-semibold tracking-tight">{@task.title}</h2>
            <p class="mt-0.5 font-mono text-xs text-zinc-500">
              {@task.workdir}
              <span :if={@task.branch} id="task-branch" class="text-zinc-400">
                · <.icon name="hero-code-bracket-micro" class="size-3" /> {@task.branch}
              </span>
            </p>
            <p
              :if={@task.agents != %{}}
              id="task-agents"
              class="mt-1 flex flex-wrap gap-x-3 font-mono text-[11px] text-zinc-500"
            >
              <span :for={{role, agent} <- @task.agents}>
                {role}: {agent["name"]} ({agent["pane_id"]})
              </span>
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-1.5">
            <.action_button
              :if={@task.stage == :todo}
              id="task-start"
              event="start"
              task_id={@task.id}
              icon="hero-play-micro"
              primary
            >
              开始
            </.action_button>
            <.action_button
              :if={@task.workflow && @task.workflow.source == :lead && @task.team_id}
              id="task-save-template"
              event="save_template"
              task_id={@task.id}
              icon="hero-bookmark-micro"
            >
              存为模板
            </.action_button>
            <.action_button
              :if={@task.stage == :done and @task.worktree}
              id="task-cleanup-worktree"
              event="cleanup_worktree"
              task_id={@task.id}
              icon="hero-trash-micro"
              confirm={"删除 worktree #{@task.worktree}？分支 #{@task.branch} 会保留，未提交的改动和 .herdr-tasks 产出会一并删除。"}
            >
              清理 worktree
            </.action_button>
            <.action_button
              :if={@task.stage in [:plan, :implement]}
              id="task-pause"
              event="toggle_pause"
              task_id={@task.id}
              icon={if @task.paused, do: "hero-play-micro", else: "hero-pause-micro"}
            >
              {if @task.paused, do: "继续", else: "暂停"}
            </.action_button>
            <.action_button
              :if={@task.stage != :done}
              id="task-cancel"
              event="cancel"
              task_id={@task.id}
              icon="hero-x-mark-micro"
              confirm="确定取消这个 task？"
            >
              取消
            </.action_button>
            <button
              type="button"
              phx-click="close"
              class="ml-1 rounded-md p-1.5 text-zinc-500 transition hover:bg-white/5 hover:text-zinc-200"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
        </header>

        <.decision_bar
          :if={@task.attention}
          task={@task}
          templates={@templates}
          host_id={@host_id}
          live_pane={@live_pane}
          comment_form={@comment_form}
        />

        <div class="min-h-0 flex-1 overflow-y-auto">
          <section
            :if={@task.workflow || @task.proposal}
            id="workflow-section"
            class="border-b border-white/5 px-5 py-4"
          >
            <div class="mb-2 flex items-center justify-between">
              <h3 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">
                {if @task.proposal, do: "待批准的流程", else: "流程"}
              </h3>
              <.simulate_bar :if={simulate?(@task)} task={@task} step={@step} />
            </div>
            <.graph
              :if={@task.proposal}
              id="proposal-graph"
              workflow={@task.proposal.workflow}
            />
            <.graph
              :if={!@task.proposal}
              id="workflow-graph"
              workflow={@task.workflow}
              current={@task.step}
              visits={@task.visits}
              edge_counts={@task.edge_counts}
              finished={@task.stage == :done and not @task.cancelled}
            />
          </section>

          <div class="grid grid-cols-1 lg:grid-cols-[22rem_1fr]">
            <div class="space-y-6 border-white/5 p-5 lg:border-r">
              <section>
                <h3 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">描述</h3>
                <p class="mt-2 text-sm leading-relaxed whitespace-pre-line text-zinc-300">
                  {@task.description}
                </p>
              </section>

              <section>
                <h3 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">时间线</h3>
                <ol :if={@task.timeline != []} id="task-timeline" class="mt-3">
                  <li
                    :for={{entry, i} <- Enum.with_index(@task.timeline)}
                    id={"entry-#{i}"}
                    class="relative flex gap-3 pb-4 last:pb-0"
                  >
                    <span
                      :if={i < length(@task.timeline) - 1}
                      class="absolute top-6 bottom-0 left-[11px] w-px bg-white/10"
                    />
                    <.entry_icon status={entry.status} />
                    <div class="min-w-0 flex-1">
                      <div class="flex items-baseline justify-between gap-2">
                        <p class="text-sm text-zinc-200">
                          {entry.label} <span class="text-zinc-500">· {entry.role}</span>
                        </p>
                        <span class="shrink-0 text-xs text-zinc-500">
                          {if entry.status in [:running, :blocked, :waiting],
                            do: "进行中",
                            else: "#{entry.minutes}m"}
                        </span>
                      </div>
                      <p
                        :if={entry.output}
                        class={[
                          "mt-0.5 text-xs",
                          if(entry.status == :failed, do: "text-amber-300/80", else: "text-zinc-500")
                        ]}
                      >
                        {entry.output}
                      </p>
                    </div>
                  </li>
                </ol>
                <p :if={@task.timeline == []} class="mt-2 text-sm text-zinc-600">还没开始。</p>
              </section>

              <section :if={@task.artifacts != []}>
                <h3 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">产出</h3>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <span
                    :for={artifact <- @task.artifacts}
                    class="inline-flex items-center gap-1 rounded-md bg-white/5 px-2 py-1 font-mono text-xs text-zinc-300 ring-1 ring-white/10"
                  >
                    <.icon
                      name={
                        if artifact == "diff",
                          do: "hero-code-bracket-micro",
                          else: "hero-document-text-micro"
                      }
                      class="size-3.5 text-zinc-500"
                    />
                    {artifact}
                  </span>
                </div>
              </section>
            </div>

            <div class="flex min-h-96 flex-col">
              <div class="flex h-10 shrink-0 items-center justify-between border-b border-white/5 px-4 text-xs">
                <span class="text-zinc-500">
                  当前 agent <span :if={@step} class="ml-1 text-zinc-300">{@step.role}</span>
                  <span :if={@live_pane} class="ml-1 font-mono text-zinc-600">({@live_pane})</span>
                </span>
                <.status_badge
                  :if={@live_pane}
                  status={get_in(@panes, [@live_pane, "agent_status"])}
                />
              </div>
              <%= if @live_pane do %>
                <div class="min-h-0 flex-1 overflow-auto bg-zinc-950 p-4">
                  <div id="task-terminal" phx-hook="Terminal" phx-update="ignore" class="w-max"></div>
                </div>
              <% else %>
                <div class="grid flex-1 place-items-center p-6 text-center">
                  <div>
                    <.icon name="hero-command-line" class="size-8 text-zinc-700" />
                    <p class="mt-3 text-sm text-zinc-500">
                      {if @task.pane_id,
                        do: "演示 pane #{@task.pane_id} 不在当前 herdr session 中",
                        else: "当前没有关联的 agent pane"}
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </aside>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :templates, :list, required: true
  attr :host_id, :string, required: true
  attr :live_pane, :string, default: nil
  attr :comment_form, :any, required: true

  defp decision_bar(assigns) do
    ~H"""
    <div id="decision-bar" class="border-b border-amber-400/20 bg-amber-400/[0.06] px-5 py-3">
      <div class="flex items-start gap-3">
        <.icon name="hero-hand-raised" class="mt-0.5 size-5 shrink-0 text-amber-300" />
        <div class="min-w-0 flex-1">
          <p class="text-sm font-medium text-amber-100">需要你决定</p>
          <p class="mt-0.5 text-sm text-amber-200/80">{@task.attention.message}</p>

          <%= case @task.attention.kind do %>
            <% :workflow_approval -> %>
              <p class="mt-2 text-sm text-zinc-300">{@task.proposal.workflow.rationale}</p>
              <p
                :if={(assignments = Map.get(@task.proposal.workflow, :assignments) || %{}) != %{}}
                id="workflow-assignments"
                class="mt-1 font-mono text-xs text-zinc-400"
              >
                分工：{Enum.map_join(assignments, "，", fn {role, name} -> "#{role} → #{name}" end)}
              </p>
              <.workflow_diff
                :if={@task.previous_workflow}
                old={@task.previous_workflow}
                new={@task.proposal.workflow}
              />
              <ul id="workflow-checks" class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
                <li
                  :for={{label, ok} <- @task.proposal.checks}
                  class={[
                    "inline-flex items-center gap-1",
                    if(ok, do: "text-emerald-300", else: "text-rose-300")
                  ]}
                >
                  <.icon
                    name={if ok, do: "hero-check-micro", else: "hero-x-mark-micro"}
                    class="size-3.5"
                  />
                  {label}
                </li>
              </ul>
              <.form
                for={@comment_form}
                id="redesign-form"
                phx-submit="redesign"
                class="mt-3 flex flex-wrap items-end gap-2"
              >
                <input type="hidden" name="task_id" value={@task.id} />
                <.decision_input
                  field={@comment_form[:text]}
                  placeholder="给 lead 的修改意见（可选）"
                />
                <.decision_button
                  id="approve-workflow"
                  event="approve_workflow"
                  task_id={@task.id}
                  icon="hero-check-micro"
                  disabled={!Enum.all?(@task.proposal.checks, &elem(&1, 1))}
                  primary
                >
                  批准流程
                </.decision_button>
                <button id="redesign" type="submit" class={secondary_button()}>
                  <.icon name="hero-arrow-path-micro" class="size-4" /> 让 lead 重新设计
                </button>
                <.decision_button
                  :for={tpl <- @templates}
                  id={"use-template-#{tpl.id}"}
                  event="use_template"
                  task_id={@task.id}
                  icon="hero-rectangle-stack-micro"
                  values={%{"template" => tpl.id}}
                  ghost
                >
                  改用{tpl.name}
                </.decision_button>
              </.form>
            <% :accept -> %>
              <.form
                for={@comment_form}
                id="send-back-form"
                phx-submit="send_back"
                class="mt-3 flex flex-wrap items-end gap-2"
              >
                <input type="hidden" name="task_id" value={@task.id} />
                <.decision_input field={@comment_form[:text]} placeholder="退回意见（可选）" />
                <.decision_button
                  id="accept-pass"
                  event="verdict"
                  task_id={@task.id}
                  icon="hero-check-micro"
                  values={%{"verdict" => "pass"}}
                  primary
                >
                  验收通过
                </.decision_button>
                <button id="send-back" type="submit" class={secondary_button()}>
                  <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> 退回修改
                </button>
              </.form>
            <% :max_loops -> %>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <.decision_button
                  id="extend"
                  event="extend"
                  task_id={@task.id}
                  icon="hero-arrow-path-micro"
                  primary
                >
                  再放行一轮
                </.decision_button>
                <span class="text-xs text-zinc-500">或退回到</span>
                <.decision_button
                  :for={step <- Enum.reject(@task.workflow.steps, &(&1.role == "human"))}
                  id={"jump-#{step.id}"}
                  event="jump"
                  task_id={@task.id}
                  icon="hero-arrow-uturn-left-micro"
                  values={%{"step" => step.id}}
                >
                  {step.label}
                </.decision_button>
                <.take_over :if={@live_pane} host_id={@host_id} pane={@live_pane} />
              </div>
            <% :blocked -> %>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <.decision_button
                  id="resume"
                  event="resume"
                  task_id={@task.id}
                  icon="hero-check-micro"
                  primary
                >
                  批准继续
                </.decision_button>
                <.take_over :if={@live_pane} host_id={@host_id} pane={@live_pane} />
              </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :step, :map, required: true

  defp simulate_bar(assigns) do
    ~H"""
    <div id="simulate-bar" class="flex flex-wrap items-center justify-end gap-1.5">
      <span class="text-[11px] text-violet-300/80">演示 · 模拟 {@step.role} 的结论：</span>
      <button
        :for={outcome <- Workflow.outcomes(@task.workflow, @task.step)}
        id={"simulate-#{outcome.on}"}
        type="button"
        phx-click="verdict"
        phx-value-id={@task.id}
        phx-value-verdict={outcome.on}
        class="rounded-md bg-violet-400/10 px-2 py-1 text-xs text-violet-200 ring-1 ring-violet-400/20 transition hover:bg-violet-400/20 active:scale-95"
      >
        {Workflow.verdict_label(outcome.on)}
      </button>
    </div>
    """
  end

  attr :old, :map, required: true
  attr :new, :map, required: true

  defp workflow_diff(assigns) do
    assigns = assign(assigns, diff: Workflow.diff(assigns.old, assigns.new))

    ~H"""
    <p id="workflow-diff" class="mt-2 flex flex-wrap gap-2 text-xs">
      <span class="text-zinc-500">v{@old.version} → v{@new.version}</span>
      <span :for={label <- @diff.added} class="rounded bg-emerald-400/10 px-1.5 text-emerald-300">
        + {label}
      </span>
      <span
        :for={label <- @diff.removed}
        class="rounded bg-rose-400/10 px-1.5 text-rose-300 line-through"
      >
        {label}
      </span>
    </p>
    """
  end

  attr :field, :any, required: true
  attr :placeholder, :string, required: true

  defp decision_input(assigns) do
    ~H"""
    <div class="min-w-64 flex-1 [&_.fieldset]:mb-0">
      <.input
        field={@field}
        type="text"
        placeholder={@placeholder}
        class="block w-full rounded-lg border-0 bg-zinc-950/60 px-3 py-1.5 text-sm text-zinc-100 ring-1 ring-white/10 placeholder:text-zinc-600 focus:ring-2 focus:ring-amber-400/50 focus:outline-none"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :task_id, :string, required: true
  attr :icon, :string, required: true
  attr :values, :map, default: %{}
  attr :primary, :boolean, default: false
  attr :ghost, :boolean, default: false
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  defp decision_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-id={@task_id}
      disabled={@disabled}
      {for {k, v} <- @values, into: %{}, do: {"phx-value-#{k}", v}}
      class={
        cond do
          @primary ->
            "inline-flex items-center gap-1 rounded-lg bg-amber-400 px-3 py-1.5 text-sm font-medium text-zinc-950 transition hover:bg-amber-300 active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40"

          @ghost ->
            "inline-flex items-center gap-1 rounded-lg px-3 py-1.5 text-sm text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"

          true ->
            secondary_button()
        end
      }
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :host_id, :string, required: true
  attr :pane, :string, required: true

  defp take_over(assigns) do
    ~H"""
    <.link
      id="take-over"
      navigate={~p"/hosts/#{@host_id}/panes/#{@pane}"}
      class="inline-flex items-center gap-1 rounded-lg px-3 py-1.5 text-sm text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
    >
      <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> 接管
    </.link>
    """
  end

  attr :form, :any, required: true
  attr :teams, :list, required: true

  defp new_task_modal(assigns) do
    team = Enum.find(assigns.teams, &(&1.id == assigns.form[:team_id].value))

    assigns =
      assign(assigns,
        workflow_options:
          [{"让 lead 设计", "lead"}] ++ for(wf <- Teams.workflows(team), do: {wf.name, wf.id})
      )

    ~H"""
    <div
      id="new-task-modal"
      class="fixed inset-0 z-40 grid place-items-center p-4"
      phx-window-keydown="close"
      phx-key="Escape"
    >
      <button
        type="button"
        phx-click="close"
        aria-label="关闭"
        class="absolute inset-0 cursor-default bg-black/60 backdrop-blur-sm"
      />
      <div class="relative w-full max-w-lg rounded-2xl bg-zinc-900 p-6 shadow-2xl ring-1 shadow-black/60 ring-white/10">
        <div class="flex items-center justify-between">
          <h2 class="text-base font-semibold">新建 Task</h2>
          <button
            type="button"
            phx-click="close"
            class="rounded-md p-1 text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="new-task-form"
          phx-change="validate"
          phx-submit="create"
          class="mt-5 space-y-4"
        >
          <.field label="标题">
            <.input
              field={@form[:title]}
              type="text"
              placeholder="一句话说明要做什么"
              class={field_class()}
            />
          </.field>
          <.field label="描述与验收标准">
            <.input
              field={@form[:description]}
              type="textarea"
              rows="4"
              placeholder="背景、约束，以及怎样算完成"
              class={field_class()}
            />
          </.field>
          <div class="grid grid-cols-2 gap-3">
            <.field label="执行方式">
              <.input
                field={@form[:executor]}
                type="select"
                options={[{"herdr agent 真实执行", "herdr"}, {"模拟（演示）", "simulated"}]}
                class={field_class()}
              />
            </.field>
            <.field label="Team">
              <.input
                field={@form[:team_id]}
                type="select"
                options={Enum.map(@teams, &{&1.name, &1.id})}
                class={field_class()}
              />
            </.field>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <.field label="优先级">
              <.input
                field={@form[:priority]}
                type="select"
                options={~w(P0 P1 P2)}
                class={field_class()}
              />
            </.field>
            <.field label="工作流">
              <.input
                field={@form[:workflow]}
                type="select"
                options={@workflow_options}
                class={field_class()}
              />
            </.field>
          </div>
          <p class="text-xs text-zinc-500">
            {cond do
              @form[:executor].value == "herdr" ->
                "开始后在 herdr 里为每个角色启动 agent，按流程逐步派活；产出写在仓库的 .herdr-tasks/ 下。"

              @form[:workflow].value == "lead" ->
                "开始后由 lead 阅读需求并提交流程图，你批准后再开工。"

              true ->
                "直接按模板流程开工。"
            end}
          </p>

          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close"
              class="rounded-lg px-3 py-2 text-sm text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
            >
              取消
            </button>
            <button
              id="new-task-submit"
              type="submit"
              class="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-medium text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98]"
            >
              创建
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div class="[&_.fieldset]:mb-0">
      <p class="mb-1.5 text-xs font-medium text-zinc-400">{@label}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :task_id, :string, required: true
  attr :icon, :string, required: true
  attr :primary, :boolean, default: false
  attr :confirm, :string, default: nil
  slot :inner_block, required: true

  defp action_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-id={@task_id}
      data-confirm={@confirm}
      class={[
        "inline-flex items-center gap-1 rounded-lg px-3 py-1.5 text-sm transition active:scale-[0.98]",
        if(@primary,
          do: "bg-emerald-500 font-medium text-zinc-950 hover:bg-emerald-400",
          else: "bg-white/5 text-zinc-200 ring-1 ring-white/10 hover:bg-white/10"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :priority, :string, required: true

  defp priority(assigns) do
    ~H"""
    <span class={[
      "rounded px-1.5 py-px text-[10px] font-semibold ring-1 ring-inset",
      case @priority do
        "P0" -> "bg-rose-400/10 text-rose-300 ring-rose-400/30"
        "P1" -> "bg-orange-400/10 text-orange-300 ring-orange-400/25"
        _ -> "bg-white/5 text-zinc-400 ring-white/10"
      end
    ]}>
      {@priority}
    </span>
    """
  end

  attr :status, :string, default: nil

  defp agent_dot(assigns) do
    ~H"""
    <span class={[
      "size-1.5 shrink-0 rounded-full",
      case @status do
        "working" -> "bg-sky-400 motion-safe:animate-pulse"
        "blocked" -> "bg-amber-400 motion-safe:animate-pulse"
        "done" -> "bg-emerald-400"
        "idle" -> "bg-zinc-400"
        _ -> "bg-zinc-600"
      end
    ]} />
    """
  end

  attr :status, :atom, required: true

  defp entry_icon(assigns) do
    ~H"""
    <span class={[
      "relative z-10 grid size-6 shrink-0 place-items-center rounded-full ring-1",
      case @status do
        :done -> "bg-emerald-400/10 text-emerald-300 ring-emerald-400/30"
        :failed -> "bg-amber-400/10 text-amber-300 ring-amber-400/30"
        :blocked -> "bg-amber-400/10 text-amber-300 ring-amber-400/30"
        :waiting -> "bg-violet-400/10 text-violet-300 ring-violet-400/30"
        _ -> "bg-sky-400/10 text-sky-300 ring-sky-400/30"
      end
    ]}>
      <.icon
        name={
          case @status do
            :done -> "hero-check-micro"
            :failed -> "hero-arrow-uturn-left-micro"
            :blocked -> "hero-hand-raised-micro"
            :waiting -> "hero-user-micro"
            _ -> "hero-ellipsis-horizontal-micro"
          end
        }
        class={["size-3.5", @status == :running && "motion-safe:animate-pulse"]}
      />
    </span>
    """
  end

  defp with_task(socket, id, fun) do
    case socket.assigns.tasks[id] do
      nil ->
        {:noreply, socket}

      task ->
        {task, message} = fun.(task)
        {:noreply, put_task(socket, task, message)}
    end
  end

  defp put_task(socket, task, message) do
    case Tasks.save_task(task) do
      {:ok, task} ->
        socket = socket |> apply_task(task) |> assign(comment_form: comment_form())
        if message, do: put_flash(socket, :info, "#{task.id} #{message}"), else: socket

      {:error, changeset} ->
        put_flash(socket, :error, "保存失败：#{inspect(changeset.errors)}")
    end
  end

  defp apply_task(socket, task) do
    socket =
      socket
      |> assign(tasks: Map.put(socket.assigns.tasks, task.id, task))
      |> stream_columns()

    if socket.assigns.task && socket.assigns.task.id == task.id,
      do:
        socket
        |> assign(task: task)
        |> LiveTerminal.watch(live_pane(socket.assigns.panes, task)),
      else: socket
  end

  defp stream_columns(socket) do
    grouped = Enum.group_by(Map.values(socket.assigns.tasks), & &1.stage)

    Enum.reduce(Demo.stages(), socket, fn stage, socket ->
      tasks = grouped |> Map.get(stage, []) |> Enum.sort_by(&{&1.priority, &1.stage_since})
      stream(socket, stage, tasks, reset: true)
    end)
  end

  defp schedule_lead(task, version, feedback) do
    Process.send_after(self(), {:lead_proposal, task.id, version, feedback}, @lead_delay_ms)
  end

  defp simulate?(task) do
    task.executor == "simulated" and task.workflow != nil and task.proposal == nil and
      task.attention == nil and not task.paused and Runner.agent_step?(task)
  end

  # Demo tasks reference real pane ids; only show a terminal when that pane exists right now.
  defp live_pane(panes, %{pane_id: pane_id}) when is_binary(pane_id) do
    if Map.has_key?(panes, pane_id), do: pane_id
  end

  defp live_pane(_panes, _task), do: nil

  defp agent_status(panes, task) do
    get_in(panes, [task.pane_id || "", "agent_status"]) || task.agent_status
  end

  defp workflow_badge(%{proposal: %{workflow: wf}}), do: "lead 设计 v#{wf.version}（待批准）"
  defp workflow_badge(%{workflow: %{source: :lead} = wf}), do: "lead 设计 v#{wf.version}"
  defp workflow_badge(%{workflow: %{name: name}}), do: name
  defp workflow_badge(_task), do: "lead 设计"

  defp count(tasks, stage), do: Enum.count(Map.values(tasks), &(&1.stage == stage))

  defp overdue?(%{stage: stage, paused: false, stage_since: since})
       when stage in [:plan, :implement],
       do: DateTime.diff(DateTime.utc_now(), since, :minute) >= 45

  defp overdue?(_task), do: false

  defp elapsed(since) do
    case DateTime.diff(DateTime.utc_now(), since, :minute) do
      m when m < 1 -> "<1m"
      m when m < 60 -> "#{m}m"
      m -> "#{div(m, 60)}h #{rem(m, 60)}m"
    end
  end

  defp validate(params, socket) do
    project = socket.assigns.project
    team = team_of(socket.assigns.teams, %{team_id: params["team_id"]})
    title = if String.trim(params["title"] || "") == "", do: [title: {"标题不能为空", []}]

    workflow =
      if params["workflow"] == "lead",
        do: %{steps: [%{role: "lead"}]},
        else: Teams.workflow(team, params["workflow"])

    team_errors =
      cond do
        team == nil ->
          [team_id: {"请选择 Team", []}]

        workflow == nil ->
          [workflow: {"#{team.name} 没有这个流程", []}]

        (missing = Teams.missing_roles(team, workflow)) != [] ->
          [workflow: {"#{team.name} 里没有这个流程需要的角色：#{Enum.join(missing, "、")}", []}]

        true ->
          []
      end

    herdr =
      if params["executor"] == "herdr" do
        [
          not File.dir?(project.path) &&
            {:executor, {"项目目录 #{project.path} 不存在，无法真实执行", []}}
        ]
      end

    Enum.filter(List.wrap(title) ++ team_errors ++ List.wrap(herdr), & &1)
  end

  defp new_task_form(socket) do
    team = Enum.find(socket.assigns.teams, & &1.is_default) || List.first(socket.assigns.teams)
    workflow = Enum.at(Teams.workflows(team), 0)

    to_form(
      %{
        "priority" => "P2",
        "workflow" => (workflow && workflow.id) || "lead",
        "executor" => "herdr",
        "team_id" => team && team.id
      },
      as: :task
    )
  end

  defp team_of(teams, %{team_id: team_id}), do: Enum.find(teams, &(&1.id == team_id))

  defp comment_form, do: to_form(%{"text" => ""}, as: :comment)

  defp now, do: DateTime.utc_now()

  defp secondary_button do
    "inline-flex items-center gap-1 rounded-lg bg-white/5 px-3 py-1.5 text-sm text-zinc-200 ring-1 ring-white/10 transition hover:bg-white/10 active:scale-[0.98]"
  end

  defp field_class do
    "block w-full rounded-lg border-0 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 ring-1 ring-white/10 placeholder:text-zinc-600 focus:ring-2 focus:ring-emerald-500/60 focus:outline-none"
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
