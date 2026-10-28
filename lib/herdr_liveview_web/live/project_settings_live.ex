defmodule HerdrLiveViewWeb.ProjectSettingsLive do
  use HerdrLiveViewWeb, :live_view

  alias HerdrLiveView.{Projects, Teams}
  alias HerdrLiveView.Teams.{Member, Team, TeamWorkflow}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get_by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "项目 #{slug} 不存在") |> push_navigate(to: ~p"/")}

      project ->
        {:ok,
         socket
         |> assign(project: project, page_title: "#{project.name} · 设置")
         |> assign(editing: nil, form: nil)
         |> load_teams()}
    end
  end

  @impl true
  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: nil)}

  def handle_event("new_team", _params, socket) do
    {:noreply,
     socket |> assign(preset: "software") |> edit({:team, nil}, Teams.change_team(%Team{}))}
  end

  def handle_event("edit_team", %{"id" => id}, socket) do
    team = find_team(socket, id)
    {:noreply, edit(socket, {:team, team}, Teams.change_team(team))}
  end

  def handle_event("new_member", %{"team" => team_id}, socket) do
    team = find_team(socket, team_id)

    {:noreply,
     edit(
       socket,
       {:member, team.id, nil},
       Teams.change_member(%Member{agent_kind: default_kind()})
     )}
  end

  def handle_event("edit_member", %{"id" => id}, socket) do
    member = find_member(socket, id)
    {:noreply, edit(socket, {:member, member.team_id, member}, Teams.change_member(member))}
  end

  def handle_event("validate", %{"team" => params}, socket) do
    {:team, team} = socket.assigns.editing
    changeset = Teams.change_team(team || %Team{}, Map.merge(params, ids(team, socket)))

    {:noreply,
     assign(socket,
       form: to_form(changeset, action: :validate),
       preset: preset(params["preset"])
     )}
  end

  def handle_event("validate", %{"member" => params}, socket) do
    {:member, team_id, member} = socket.assigns.editing

    changeset =
      Teams.change_member(
        member || %Member{},
        Map.merge(params, %{"id" => (member && member.id) || "new", "team_id" => team_id})
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"team" => params}, socket) do
    result =
      case socket.assigns.editing do
        {:team, nil} ->
          Teams.create_team(socket.assigns.project.id, params, preset(params["preset"]))

        {:team, team} ->
          Teams.update_team(team, params)
      end

    saved(socket, result, "Team 已保存")
  end

  def handle_event("save", %{"member" => params}, socket) do
    result =
      case socket.assigns.editing do
        {:member, team_id, nil} -> Teams.create_member(team_id, params)
        {:member, _team_id, member} -> Teams.update_member(member, params)
      end

    saved(socket, result, "成员已保存")
  end

  def handle_event("delete_member", %{"id" => id}, socket) do
    case socket |> find_member(id) |> Teams.delete_member() do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "成员已删除") |> load_teams()}

      {:error, :last_lead} ->
        {:noreply, put_flash(socket, :error, "Team 至少要保留一个 lead")}
    end
  end

  def handle_event("delete_workflow", %{"id" => id}, socket) do
    tw = socket.assigns.teams |> Enum.flat_map(& &1.workflows) |> Enum.find(&(&1.id == id))
    {:ok, _} = Teams.delete_workflow(tw)
    {:noreply, socket |> put_flash(:info, "流程已删除") |> load_teams()}
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    {:ok, _} = socket |> find_team(id) |> Teams.set_default()
    {:noreply, load_teams(socket)}
  end

  def handle_event("delete_team", %{"id" => id}, socket) do
    case socket |> find_team(id) |> Teams.delete_team() do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Team 已删除") |> load_teams()}
      {:error, :default_team} -> {:noreply, put_flash(socket, :error, "默认 Team 不能删除")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <:crumb>
        <.link
          navigate={~p"/p/#{@project.slug}"}
          class="truncate font-medium text-zinc-200 hover:underline"
        >
          {@project.name}
        </.link>
        <span class="text-zinc-500">设置</span>
      </:crumb>

      <div class="mx-auto h-full max-w-5xl overflow-y-auto p-6">
        <section class="rounded-2xl bg-zinc-900/60 p-5 ring-1 ring-white/5">
          <h2 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">项目</h2>
          <dl class="mt-3 grid grid-cols-[8rem_1fr] gap-y-2 text-sm">
            <dt class="text-zinc-500">短名</dt>
            <dd class="font-mono">{@project.slug}</dd>
            <dt class="text-zinc-500">Host</dt>
            <dd>{@project.host.name}</dd>
            <dt class="text-zinc-500">目录</dt>
            <dd class="font-mono">{@project.path}</dd>
            <dt class="text-zinc-500">默认分支</dt>
            <dd class="font-mono">{@project.default_branch}</dd>
          </dl>
        </section>

        <div class="mt-8 flex items-center justify-between">
          <h2 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">Teams</h2>
          <button id="new-team" type="button" phx-click="new_team" class={primary_button()}>
            <.icon name="hero-plus-micro" class="size-4" /> 新建 Team
          </button>
        </div>

        <div id="teams" phx-update="stream" class="mt-3 space-y-4">
          <section
            :for={{dom_id, team} <- @streams.teams}
            id={dom_id}
            class="rounded-2xl bg-zinc-900/60 ring-1 ring-white/5"
          >
            <header class="flex flex-wrap items-start justify-between gap-3 border-b border-white/5 px-5 py-4">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <h3 class="text-base font-semibold">{team.name}</h3>
                  <span
                    :if={team.is_default}
                    class="rounded bg-emerald-400/10 px-1.5 text-[11px] text-emerald-300 ring-1 ring-emerald-400/20"
                  >
                    默认
                  </span>
                </div>
                <p :if={team.description != ""} class="mt-0.5 text-sm text-zinc-400">
                  {team.description}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  最多同时 {team.max_concurrent_tasks} 个 task · 每步超时 {team.step_timeout_min} 分钟
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-1">
                <button
                  :if={!team.is_default}
                  id={"set-default-#{team.id}"}
                  type="button"
                  phx-click="set_default"
                  phx-value-id={team.id}
                  class={ghost_button()}
                >
                  设为默认
                </button>
                <button
                  type="button"
                  phx-click="edit_team"
                  phx-value-id={team.id}
                  class={ghost_button()}
                >
                  编辑
                </button>
                <button
                  :if={!team.is_default}
                  id={"delete-team-#{team.id}"}
                  type="button"
                  phx-click="delete_team"
                  phx-value-id={team.id}
                  data-confirm={"删除 Team #{team.name}？它的 task 会失去 Team。"}
                  class={ghost_button()}
                >
                  删除
                </button>
              </div>
            </header>

            <table class="w-full text-sm">
              <thead class="text-left text-xs whitespace-nowrap text-zinc-500">
                <tr>
                  <th class="px-5 py-2 font-medium">成员</th>
                  <th class="px-2 py-2 font-medium">角色</th>
                  <th class="px-2 py-2 font-medium">agent</th>
                  <th class="px-2 py-2 font-medium">启动参数</th>
                  <th class="px-2 py-2 font-medium">生命周期</th>
                  <th class="px-5 py-2"></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={member <- team.members}
                  id={"member-#{member.id}"}
                  class="border-t border-white/5"
                >
                  <td class="px-5 py-2">
                    <p class="font-mono">{member.name}</p>
                    <p :if={member.duty != ""} class="text-xs text-zinc-400">{member.duty}</p>
                    <p :if={member.notes != ""} class="text-xs text-zinc-500">{member.notes}</p>
                  </td>
                  <td class="px-2 py-2 text-zinc-300">{member.role}</td>
                  <td class="px-2 py-2 text-zinc-300">{member.agent_kind}</td>
                  <td class="max-w-56 truncate px-2 py-2 font-mono text-xs text-zinc-400">
                    {member.agent_args}
                  </td>
                  <td class="px-2 py-2 text-xs text-zinc-400">
                    {if member.lifetime == "resident", do: "常驻", else: "临时"}
                  </td>
                  <td class="px-5 py-2 text-right whitespace-nowrap">
                    <button
                      type="button"
                      phx-click="edit_member"
                      phx-value-id={member.id}
                      class={ghost_button()}
                    >
                      编辑
                    </button>
                    <button
                      id={"delete-member-#{member.id}"}
                      type="button"
                      phx-click="delete_member"
                      phx-value-id={member.id}
                      data-confirm={"删除成员 #{member.name}？"}
                      class={ghost_button()}
                    >
                      删除
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
            <div class="px-5 py-3">
              <button
                id={"new-member-#{team.id}"}
                type="button"
                phx-click="new_member"
                phx-value-team={team.id}
                class={ghost_button()}
              >
                <.icon name="hero-plus-micro" class="size-4" /> 添加成员
              </button>
            </div>

            <div class="border-t border-white/5 px-5 py-4">
              <h4 class="text-xs font-medium text-zinc-500">流程模板</h4>
              <p :if={team.workflows == []} class="mt-2 text-xs text-zinc-500">
                还没有模板，新建 task 时由 lead 按成员和职责设计流程。
              </p>
              <ul class="mt-2 space-y-2">
                <li
                  :for={tw <- team.workflows}
                  id={"workflow-#{tw.id}"}
                  class="flex items-start justify-between gap-3 rounded-lg bg-white/[0.02] px-3 py-2 ring-1 ring-white/5"
                >
                  <div class="min-w-0">
                    <p class="text-sm">{tw.name}</p>
                    <p class="mt-0.5 text-xs text-zinc-500">
                      {tw |> TeamWorkflow.workflow() |> chain()}
                    </p>
                    <p
                      :if={(missing = Teams.missing_roles(team, TeamWorkflow.workflow(tw))) != []}
                      class="mt-0.5 text-xs text-amber-300"
                    >
                      缺少角色：{Enum.join(missing, "、")}
                    </p>
                  </div>
                  <button
                    id={"delete-workflow-#{tw.id}"}
                    type="button"
                    phx-click="delete_workflow"
                    phx-value-id={tw.id}
                    data-confirm={"删除流程 #{tw.name}？"}
                    class={ghost_button()}
                  >
                    删除
                  </button>
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>

      <.modal :if={@form} title={modal_title(@editing)}>
        <.form
          :let={f}
          for={@form}
          id="settings-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4 [&_.fieldset]:mb-0"
        >
          <%= case @editing do %>
            <% {:team, team} -> %>
              <.labeled :if={team == nil} label="预设">
                <.input
                  name="team[preset]"
                  value={@preset}
                  type="select"
                  options={Teams.presets()}
                  class={field_class()}
                />
              </.labeled>
              <.labeled label="名称">
                <.input field={f[:name]} type="text" class={field_class()} />
              </.labeled>
              <.labeled label="说明">
                <.input field={f[:description]} type="textarea" rows="2" class={field_class()} />
              </.labeled>
              <div class="grid grid-cols-2 gap-3">
                <.labeled label="最多同时执行的 task">
                  <.input field={f[:max_concurrent_tasks]} type="number" class={field_class()} />
                </.labeled>
                <.labeled label="每步超时（分钟）">
                  <.input field={f[:step_timeout_min]} type="number" class={field_class()} />
                </.labeled>
              </div>
            <% {:member, _, _} -> %>
              <div class="grid grid-cols-2 gap-3">
                <.labeled label="成员名">
                  <.input field={f[:name]} type="text" placeholder="coder-fast" class={field_class()} />
                </.labeled>
                <.labeled label="角色">
                  <.input
                    field={f[:role]}
                    type="text"
                    placeholder="如 coder、analyst、lead"
                    class={[field_class(), "font-mono"]}
                  />
                </.labeled>
                <.labeled label="agent">
                  <.input
                    field={f[:agent_kind]}
                    type="select"
                    options={Member.kinds()}
                    class={field_class()}
                  />
                </.labeled>
                <.labeled label="生命周期">
                  <.input
                    field={f[:lifetime]}
                    type="select"
                    options={[{"常驻（task 验收后回收）", "resident"}, {"临时（做完即回收）", "ephemeral"}]}
                    class={field_class()}
                  />
                </.labeled>
              </div>
              <.labeled label="职责（每一步都会告诉 agent）">
                <.input
                  field={f[:duty]}
                  type="textarea"
                  rows="2"
                  placeholder="如：查找财报和行业数据，给出来源"
                  class={field_class()}
                />
              </.labeled>
              <.labeled label="启动参数（含预先放行的工具）">
                <.input
                  field={f[:agent_args]}
                  type="text"
                  placeholder="--allow-tool write --allow-tool 'shell(git:*)'"
                  class={[field_class(), "font-mono"]}
                />
              </.labeled>
              <.labeled label="说明（给 Leader 选人时看）">
                <.input
                  field={f[:notes]}
                  type="text"
                  placeholder="适合复杂重构"
                  class={field_class()}
                />
              </.labeled>
          <% end %>
          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="close" class={ghost_button()}>取消</button>
            <button id="settings-submit" type="submit" class={primary_button()}>保存</button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp modal(assigns) do
    ~H"""
    <div
      id="settings-modal"
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
      <div class="relative w-full max-w-xl rounded-2xl bg-zinc-900 p-6 shadow-2xl ring-1 shadow-black/60 ring-white/10">
        <h2 class="mb-5 text-base font-semibold">{@title}</h2>
        {render_slot(@inner_block)}
      </div>
    </div>
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

  defp load_teams(socket) do
    teams = Teams.list_teams(socket.assigns.project.id)

    socket
    |> assign(teams: teams)
    |> stream(:teams, teams, reset: true)
  end

  defp saved(socket, {:ok, _}, message) do
    {:noreply,
     socket |> put_flash(:info, message) |> assign(editing: nil, form: nil) |> load_teams()}
  end

  defp saved(socket, {:error, changeset}, _message) do
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  defp edit(socket, editing, changeset),
    do: assign(socket, editing: editing, form: to_form(changeset))

  defp find_team(socket, id), do: Enum.find(socket.assigns.teams, &(&1.id == id))

  defp preset("blank"), do: "blank"
  defp preset(_), do: "software"

  defp chain(workflow), do: Enum.map_join(workflow.steps, " → ", &"#{&1.label}（#{&1.role}）")

  defp find_member(socket, id) do
    socket.assigns.teams |> Enum.flat_map(& &1.members) |> Enum.find(&(&1.id == id))
  end

  defp ids(nil, socket), do: %{"id" => "new", "project_id" => socket.assigns.project.id}
  defp ids(team, _socket), do: %{"id" => team.id, "project_id" => team.project_id}

  defp default_kind, do: elem(Teams.configured_agent(), 0)

  defp modal_title({:team, nil}), do: "新建 Team"
  defp modal_title({:team, _}), do: "编辑 Team"
  defp modal_title({:member, _, nil}), do: "添加成员"
  defp modal_title({:member, _, _}), do: "编辑成员"

  defp primary_button do
    "inline-flex items-center gap-1 rounded-lg bg-emerald-500 px-3 py-1.5 text-sm font-medium text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98]"
  end

  defp ghost_button do
    "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs whitespace-nowrap text-zinc-400 transition hover:bg-white/5 hover:text-zinc-200"
  end

  defp field_class do
    "block w-full rounded-lg border-0 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 ring-1 ring-white/10 placeholder:text-zinc-600 focus:ring-2 focus:ring-emerald-500/60 focus:outline-none"
  end
end
