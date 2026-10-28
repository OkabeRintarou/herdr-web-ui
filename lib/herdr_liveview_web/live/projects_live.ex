defmodule HerdrLiveViewWeb.ProjectsLive do
  use HerdrLiveViewWeb, :live_view

  alias HerdrLiveView.Herdr.Panes
  alias HerdrLiveView.{Hosts, Projects, Tasks}
  alias HerdrLiveView.Hosts.Host

  @impl true
  def mount(_params, _session, socket) do
    hosts = Hosts.list_hosts()

    if connected?(socket) do
      Tasks.subscribe()
      Enum.each(hosts, &Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic(&1.id)))
    end

    {:ok,
     socket
     |> assign(
       hosts: hosts,
       host_status: Map.new(hosts, &{&1.id, elem(Panes.snapshot(&1.id), 0)}),
       host_checks: %{}
     )
     |> assign(page_title: "项目")
     |> stream_configure(:attention, dom_id: &"attention-#{&1.id}")
     |> refresh()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    form =
      if socket.assigns.live_action == :new,
        do: to_form(Projects.change_project(%Projects.Project{}, default_attrs(socket))),
        else: nil

    host_form =
      if socket.assigns.live_action == :new_host,
        do: to_form(Hosts.change_host(%Host{kind: "ssh"}), as: :host),
        else: nil

    {:noreply, assign(socket, form: form, host_form: host_form, slug_touched: false)}
  end

  @impl true
  def handle_info({:task_saved, _task}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:herdr_panes, _status, _panes}, socket) do
    # the message doesn't say which host it came from; re-read all (a handful of hosts)
    statuses = Map.new(socket.assigns.hosts, &{&1.id, elem(Panes.snapshot(&1.id), 0)})
    {:noreply, assign(socket, host_status: statuses)}
  end

  @impl true
  def handle_event("close", _params, socket), do: {:noreply, push_patch(socket, to: ~p"/")}

  def handle_event("validate", %{"project" => params}, socket) do
    slug_touched = socket.assigns.slug_touched or params["_target"] == ["project", "slug"]

    params =
      if slug_touched,
        do: params,
        else: Map.put(params, "slug", Projects.slugify(params["name"] || ""))

    changeset =
      %Projects.Project{}
      |> Projects.change_project(Map.put_new(params, "id", "pending"))
      |> Projects.validate_local_path()

    {:noreply,
     assign(socket, form: to_form(changeset, action: :validate), slug_touched: slug_touched)}
  end

  def handle_event("validate_host", %{"host" => params}, socket) do
    changeset =
      Hosts.change_host(%Host{}, Map.merge(params, %{"id" => "h-pending", "kind" => "ssh"}))

    {:noreply, assign(socket, host_form: to_form(changeset, action: :validate, as: :host))}
  end

  def handle_event("create_host", %{"host" => params}, socket) do
    case Hosts.create_host(Map.put(params, "kind", "ssh")) do
      {:ok, host} ->
        Hosts.connect(host)
        hosts = Hosts.list_hosts()
        Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic(host.id))

        {:noreply,
         socket
         |> assign(hosts: hosts)
         |> put_flash(:info, "已添加 #{host.name}，正在连接")
         |> push_patch(to: ~p"/")
         |> check_host(host)}

      {:error, changeset} ->
        {:noreply, assign(socket, host_form: to_form(changeset, as: :host))}
    end
  end

  def handle_event("check_host", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.hosts, &(&1.id == id)) do
      nil -> {:noreply, socket}
      host -> {:noreply, check_host(socket, host)}
    end
  end

  def handle_event("create", %{"project" => params}, socket) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "已创建项目 #{project.name}")
         |> push_navigate(to: ~p"/p/#{project.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_async({:check, id}, {:ok, results}, socket),
    do: {:noreply, update(socket, :host_checks, &Map.put(&1, id, results))}

  def handle_async({:check, id}, {:exit, reason}, socket) do
    results = [{"检测", {:error, inspect(reason)}}]
    {:noreply, update(socket, :host_checks, &Map.put(&1, id, results))}
  end

  defp check_host(socket, host) do
    socket
    |> update(:host_checks, &Map.put(&1, host.id, :running))
    |> start_async({:check, host.id}, fn -> Hosts.check(host) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <:status>
        <.link
          id="new-project"
          patch={~p"/projects/new"}
          class="inline-flex items-center gap-1 rounded-lg bg-emerald-500 px-2 py-1.5 text-xs font-medium whitespace-nowrap text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98] sm:px-3"
        >
          <.icon name="hero-plus-micro" class="size-4" />
          <span class="hidden sm:inline">新建项目</span>
        </.link>
      </:status>

      <div class="mx-auto grid h-full max-w-7xl gap-6 overflow-y-auto p-6 lg:grid-cols-[1fr_22rem]">
        <section>
          <h1 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">项目</h1>
          <div id="projects" phx-update="stream" class="mt-3 grid gap-3 sm:grid-cols-2">
            <p
              id="projects-empty"
              class="hidden rounded-xl border border-dashed border-white/10 p-8 text-center text-sm text-zinc-500 only:block"
            >
              还没有项目。
            </p>
            <.link
              :for={{dom_id, project} <- @streams.projects}
              id={dom_id}
              navigate={~p"/p/#{project.slug}"}
              class="group rounded-2xl bg-zinc-900/60 p-4 ring-1 ring-white/5 transition hover:-translate-y-px hover:bg-zinc-900 hover:ring-white/10"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-base font-semibold tracking-tight">{project.name}</p>
                  <p class="mt-0.5 truncate font-mono text-xs text-zinc-500">{project.path}</p>
                </div>
                <span class="inline-flex shrink-0 items-center gap-1.5 text-xs text-zinc-400">
                  <span class={[
                    "size-1.5 rounded-full",
                    if(@host_status[project.host_id] == :connected,
                      do: "bg-emerald-400",
                      else: "bg-amber-400"
                    )
                  ]} />
                  {project.host.name}
                </span>
              </div>
              <div class="mt-4 flex flex-wrap gap-1.5 text-xs">
                <.count_chip label="待办" n={count(@counts, project.id, [:todo])} />
                <.count_chip
                  label="进行中"
                  n={count(@counts, project.id, [:plan, :implement])}
                  tone="sky"
                />
                <.count_chip
                  label="待人处理"
                  n={count(@counts, project.id, [:attention])}
                  tone="amber"
                />
                <.count_chip label="完成" n={count(@counts, project.id, [:done])} tone="emerald" />
              </div>
            </.link>
          </div>
        </section>

        <aside>
          <h2 class="flex items-center gap-1.5 text-xs font-medium tracking-wider text-amber-300/90 uppercase">
            <.icon name="hero-hand-raised-micro" class="size-4" /> 待人处理
            <span class="rounded-full bg-amber-400/10 px-1.5 text-[11px] text-amber-300">
              {@attention_count}
            </span>
          </h2>
          <ul id="attention" phx-update="stream" class="mt-3 space-y-2">
            <li
              id="attention-empty"
              class="hidden rounded-xl border border-dashed border-white/10 p-6 text-center text-xs text-zinc-600 only:block"
            >
              没有需要你处理的 task。
            </li>
            <li :for={{dom_id, task} <- @streams.attention} id={dom_id}>
              <.link
                navigate={~p"/p/#{@slugs[task.project_id]}/tasks/#{task.id}"}
                class="block rounded-xl bg-amber-400/[0.04] p-3 ring-1 ring-amber-400/20 transition hover:bg-amber-400/[0.08]"
              >
                <p class="text-[11px] text-zinc-500">{@names[task.project_id]} · {task.id}</p>
                <p class="mt-0.5 truncate text-sm font-medium text-zinc-100">{task.title}</p>
                <p :if={task.attention} class="mt-1 line-clamp-2 text-xs text-amber-200/80">
                  {task.attention.message}
                </p>
              </.link>
            </li>
          </ul>

          <div class="mt-8 flex items-center justify-between">
            <h2 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">Hosts</h2>
            <.link
              id="new-host"
              patch={~p"/hosts/new"}
              class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
            >
              <.icon name="hero-plus-micro" class="size-4" /> SSH Host
            </.link>
          </div>
          <ul id="hosts" class="mt-3 space-y-2">
            <li
              :for={host <- @hosts}
              id={"host-#{host.id}"}
              class="rounded-xl bg-zinc-900/60 p-3 ring-1 ring-white/5"
            >
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <p class="flex items-center gap-1.5 text-sm font-medium">
                    <span class={[
                      "size-1.5 rounded-full",
                      if(@host_status[host.id] == :connected,
                        do: "bg-emerald-400",
                        else: "bg-amber-400"
                      )
                    ]} />
                    {host.name}
                  </p>
                  <p class="mt-0.5 truncate font-mono text-[11px] text-zinc-500">
                    {if host.kind == "ssh", do: "ssh #{host.ssh_target}", else: "本机"} · 最多 {host.max_agents} 个 agent
                  </p>
                </div>
                <button
                  id={"check-host-#{host.id}"}
                  type="button"
                  phx-click="check_host"
                  phx-value-id={host.id}
                  disabled={@host_checks[host.id] == :running}
                  class="shrink-0 rounded-md px-2 py-1 text-xs whitespace-nowrap text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200 disabled:opacity-50"
                >
                  {if @host_checks[host.id] == :running, do: "检测中…", else: "检测连接"}
                </button>
              </div>
              <ul
                :if={is_list(@host_checks[host.id])}
                id={"host-checks-#{host.id}"}
                class="mt-2 space-y-0.5 text-xs"
              >
                <li
                  :for={{label, result} <- @host_checks[host.id]}
                  class={if(result == :ok, do: "text-emerald-300", else: "text-rose-300")}
                >
                  {if result == :ok, do: "✓", else: "✗"} {label}
                  <span :if={result != :ok} class="block pl-4 break-all text-rose-300/80">
                    {elem(result, 1)}
                  </span>
                </li>
              </ul>
            </li>
          </ul>
        </aside>
      </div>

      <div
        :if={@live_action == :new_host and @host_form}
        id="new-host-modal"
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
          <h2 class="text-base font-semibold">添加 SSH Host</h2>
          <p class="mt-1 text-xs text-zinc-500">
            需要能免密登录（ssh 密钥或 agent），远端已安装 git 并运行着 herdr。
          </p>
          <.form
            for={@host_form}
            id="new-host-form"
            phx-change="validate_host"
            phx-submit="create_host"
            class="mt-5 space-y-4 [&_.fieldset]:mb-0"
          >
            <.labeled label="名称">
              <.input
                field={@host_form[:name]}
                type="text"
                placeholder="例如 gpu-box"
                class={field_class()}
              />
            </.labeled>
            <.labeled label="ssh 目标（user@host 或 ~/.ssh/config 里的别名）">
              <.input
                field={@host_form[:ssh_target]}
                type="text"
                placeholder="me@10.0.0.5"
                class={[field_class(), "font-mono"]}
              />
            </.labeled>
            <.labeled label="远端 herdr socket">
              <.input
                field={@host_form[:remote_socket]}
                type="text"
                placeholder="~/.config/herdr/sessions/<会话名>/herdr.sock"
                class={[field_class(), "font-mono"]}
              />
            </.labeled>
            <.labeled label="最多同时运行的 agent">
              <.input field={@host_form[:max_agents]} type="number" class={field_class()} />
            </.labeled>
            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                phx-click="close"
                class="rounded-lg px-3 py-2 text-sm text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
              >
                取消
              </button>
              <button
                id="new-host-submit"
                type="submit"
                class="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-medium text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98]"
              >
                添加
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div
        :if={@live_action == :new and @form}
        id="new-project-modal"
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
          <h2 class="text-base font-semibold">新建项目</h2>
          <.form
            for={@form}
            id="new-project-form"
            phx-change="validate"
            phx-submit="create"
            class="mt-5 space-y-4 [&_.fieldset]:mb-0"
          >
            <.labeled label="名称">
              <.input
                field={@form[:name]}
                type="text"
                placeholder="例如 herdr web ui"
                class={field_class()}
              />
            </.labeled>
            <.labeled label="短名（用于 URL）">
              <.input field={@form[:slug]} type="text" class={field_class()} />
            </.labeled>
            <.labeled label="Host">
              <.input
                field={@form[:host_id]}
                type="select"
                options={Enum.map(@hosts, &{&1.name, &1.id})}
                class={field_class()}
              />
            </.labeled>
            <.labeled label="目录（绝对路径）">
              <.input
                field={@form[:path]}
                type="text"
                placeholder="/home/me/project"
                class={field_class()}
              />
            </.labeled>
            <.labeled label="默认分支">
              <.input field={@form[:default_branch]} type="text" class={field_class()} />
            </.labeled>
            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                phx-click="close"
                class="rounded-lg px-3 py-2 text-sm text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
              >
                取消
              </button>
              <button
                id="new-project-submit"
                type="submit"
                class="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-medium text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98]"
              >
                创建
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :n, :integer, required: true
  attr :tone, :string, default: "zinc"

  defp count_chip(assigns) do
    ~H"""
    <span class={[
      "rounded-md px-2 py-0.5 ring-1 ring-inset",
      cond do
        @n == 0 -> "bg-white/[0.02] text-zinc-600 ring-white/5"
        @tone == "sky" -> "bg-sky-400/10 text-sky-300 ring-sky-400/20"
        @tone == "amber" -> "bg-amber-400/10 text-amber-300 ring-amber-400/30"
        @tone == "emerald" -> "bg-emerald-400/10 text-emerald-300 ring-emerald-400/20"
        true -> "bg-white/5 text-zinc-300 ring-white/10"
      end
    ]}>
      {@label} {@n}
    </span>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp labeled(assigns) do
    ~H"""
    <div>
      <p class="mb-1.5 text-xs font-medium text-zinc-400">{@label}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp refresh(socket) do
    projects = Projects.list_projects()
    attention = Tasks.list_attention()

    socket
    |> assign(
      counts: Tasks.stage_counts(),
      attention_count: length(attention),
      slugs: Map.new(projects, &{&1.id, &1.slug}),
      names: Map.new(projects, &{&1.id, &1.name})
    )
    |> stream(:projects, projects, reset: true)
    |> stream(:attention, attention, reset: true)
  end

  defp count(counts, project_id, stages),
    do: counts |> Map.get(project_id, %{}) |> Map.take(stages) |> Map.values() |> Enum.sum()

  defp default_attrs(socket) do
    %{"host_id" => socket.assigns.hosts |> List.first() |> then(&(&1 && &1.id))}
  end

  defp field_class do
    "block w-full rounded-lg border-0 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 ring-1 ring-white/10 placeholder:text-zinc-600 focus:ring-2 focus:ring-emerald-500/60 focus:outline-none"
  end
end
