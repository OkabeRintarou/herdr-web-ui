defmodule HerdrLiveView.Tasks.Demo do
  @moduledoc "Sample tasks for previewing the board; histories are replayed through `Runner`."

  alias HerdrLiveView.Tasks.{Runner, Workflow}

  @stages [:todo, :plan, :implement, :attention, :done]

  def stages, do: @stages

  def tasks(now \\ DateTime.utc_now()) do
    [
      build(now, "t-101", "修复登录页 token 过期后不跳转", "P1", "lead", nil, [],
        description: "token 过期时前端停留在空白页。验收：过期后自动跳到登录页并保留 return_to。",
        repo: "~/web-app",
        age: 40
      ),
      build(now, "t-102", "给 CLI 增加 --json 输出", "P2", "quick", nil, [],
        description: "所有 list 子命令支持 --json，字段与 API 保持一致。",
        repo: "~/tools/cli",
        age: 95
      ),
      build(now, "t-103", "HRR Phase 2：ResNet50 拷贝路径", "P0", "lead", "w3:p6", [:start],
        description: "设计 Phase 2 的拷贝类型拆分方案，包含风险与回滚策略。",
        repo: "~/amdesvt",
        age: 6
      ),
      build(
        now,
        "t-110",
        "pane.read 分页读取",
        "P1",
        "lead",
        nil,
        [:start, {:propose, 4}],
        description: "长输出分页读取，避免一次读取超大缓冲；需要兼容旧客户端。",
        repo: "~/herdr-web-ui",
        age: 9
      ),
      build(
        now,
        "t-106",
        "统一错误码映射表",
        "P2",
        "standard",
        "w1:p2",
        [:start, {"done", 9}, {"changes_requested", 5, "缺少回滚方案"}, {"done", 6}],
        description: "把散落的错误码映射收敛到一个模块，补充单测。",
        repo: "~/rocmrt",
        age: 25
      ),
      build(
        now,
        "t-104",
        "ESVT compute 队列修复",
        "P1",
        "standard",
        "w1:p4",
        [
          :start,
          {"done", 8},
          {"pass", 4},
          {"done", 25},
          {"changes_requested", 6, "2 个竞争条件未处理"},
          {"done", 11}
        ],
        description: "按 openspec 修复 compute 队列在多流下的竞争。验收：回归用例全过。",
        repo: "~/amdesvt",
        age: 70
      ),
      build(
        now,
        "t-111",
        "多流同步改为事件驱动",
        "P1",
        "standard",
        nil,
        [:start, {"done", 6}, {"pass", 3}, {"done", 30}, {"needs_replan", 4, "现有锁模型无法支持跨设备事件"}],
        description: "实现中发现原方案依赖的锁模型不成立，被打回重新规划。",
        repo: "~/amdesvt",
        age: 50
      ),
      build(now, "t-105", "补齐 CLI 帮助文本", "P2", "quick", nil, [:start, :pause],
        description: "所有子命令补齐 --help 示例。",
        repo: "~/tools/cli",
        age: 64
      ),
      build(
        now,
        "t-107",
        "Codex 沙箱权限配置",
        "P0",
        "quick",
        "w1:p1",
        [:start, {:block, "coder 请求执行 sudo apparmor_parser，需要人工审批"}],
        description: "为 bwrap 写 AppArmor profile，使 codex sandbox 可用。",
        repo: "~/infra",
        age: 3
      ),
      build(
        now,
        "t-108",
        "PR #12000 power cap 校验",
        "P1",
        "quick",
        nil,
        [
          :start,
          {"done", 20},
          {"changes_requested", 5, "3 个调用点缺门控"},
          {"done", 11},
          {"changes_requested", 4, "仍缺 1 个调用点"},
          {"done", 9},
          {"changes_requested", 5, "set -o 路径未覆盖"}
        ],
        description: "所有调用点补齐 supported_power_cap 门控。",
        repo: "~/amdsmi",
        age: 60
      ),
      build(
        now,
        "t-112",
        "清理过期的 feature flag",
        "P2",
        "quick",
        nil,
        [:start, {"done", 12}, {"pass", 4}],
        description: "删除已全量开启超过 30 天的 flag。",
        repo: "~/web-app",
        age: 20
      ),
      build(
        now,
        "t-109",
        "API 覆盖率统计脚本",
        "P2",
        "standard",
        nil,
        [:start, {"done", 5}, {"pass", 3}, {"done", 22}, {"pass", 6}, {"pass", 2}],
        description: "以 nm -D 为基准统计导出与实现数量。",
        repo: "~/rocmrt",
        age: 180
      )
    ]
  end

  # Replays `actions` from `age` minutes ago so timelines carry realistic durations.
  defp build(now, id, title, priority, workflow, pane_id, actions, opts) do
    start = DateTime.add(now, -Keyword.fetch!(opts, :age) * 60, :second)

    task =
      Runner.new(
        %{
          "id" => id,
          "title" => title,
          "priority" => priority,
          "workflow" => workflow,
          "pane_id" => pane_id,
          "description" => opts[:description],
          "repo" => opts[:repo]
        },
        start
      )

    {task, _clock} =
      Enum.reduce(actions, {task, start}, fn action, {task, clock} ->
        play(action, task, clock)
      end)

    task
  end

  defp play(:start, task, clock), do: {Runner.start(task, clock), clock}
  defp play(:pause, task, clock), do: {Runner.toggle_pause(task), clock}
  defp play({:block, message}, task, clock), do: {Runner.block(task, message), clock}

  defp play({:propose, minutes}, task, clock) do
    clock = DateTime.add(clock, minutes * 60, :second)
    {Runner.propose(task, Workflow.propose(task), clock), clock}
  end

  defp play({verdict, minutes}, task, clock), do: play({verdict, minutes, nil}, task, clock)

  defp play({verdict, minutes, note}, task, clock) do
    clock = DateTime.add(clock, minutes * 60, :second)
    {Runner.verdict(task, verdict, note, clock), clock}
  end
end
