# claude-code-dispatcher

**Plan-and-dispatch workflow skill for Claude Code.** 上层 agent 在对话框里讨论需求、写结构化指令、投递到 tmux 后台，由 Claude Code 在 worktree 隔离里执行 + 自动验收 + 失败升舱，全部经磁盘文件持久化、跨会话可恢复。

---

## 架构

```
┌─────────────────────┐
│  对话框 (上层 agent) │
│  写指令 → 投递      │
└──────────┬──────────┘
           │ tmux send-keys
           ▼
┌─────────────────────┐         ┌──────────────────┐
│  tmux qx-{ws} 会话  │ ──────► │  qx-workflow.sh  │
│  (后台滚动窗口)     │         │  (执行引擎)      │
└─────────────────────┘         └────────┬─────────┘
                                          │ exec → claude
                                          │ verify → bash
                                          │ escalate → claude
                                          ▼
                                ┌──────────────────┐
                                │  /tmp/qx-* 标记  │
                                │  /tmp/qx-* 日志  │
                                │  observer 集成   │
                                └──────────────────┘
```

## 三层文件

| 层 | 路径 | 作用 |
|----|------|------|
| 权威源 | `~/program/claude-code-dispatcher/` | 唯一真实文件,git 仓库 |
| skill 加载 symlink | `~/.claude/skills/claude-code-dispatcher/` | Claude Code 读取 |
| 兼容性 symlink | `~/.agents/skills/{claude-code-dispatcher,task-dispatcher}` | 历史 Agent 系统读取 |

## 安装

```bash
git clone git@github.com:hanrry2323/claude-code-dispatcher.git ~/program/claude-code-dispatcher
mkdir -p ~/.claude/skills
ln -sfn ~/program/claude-code-dispatcher ~/.claude/skills/claude-code-dispatcher
# 可选：兼容旧 Agent 系统
mkdir -p ~/.agents/skills
ln -sfn ~/program/claude-code-dispatcher ~/.agents/skills/claude-code-dispatcher
ln -sfn ~/program/claude-code-dispatcher ~/.agents/skills/task-dispatcher
```

## 使用

加载 skill 后,上层 agent 会自动按 SKILL.md 描述的流程工作。核心：

```bash
SCRIPT=$HOME/program/claude-code-dispatcher/qx-workflow.sh
tmux send-keys -t qx-{workspace} "cd {project_dir} && \
  $SCRIPT {task_id} {workspace} \
  /tmp/qx-workflow-{workspace}-{task_id}-exec.txt \
  /tmp/qx-workflow-{workspace}-{task_id}-verify.txt" Enter
```

## 任务指令模板

`exec.txt`（Goal-合同格式）：

```
## Goal
End state:
  - 期望终态描述
Evidence:
  - 验收命令 1 → exit 0
  - 验收命令 2 → exit 0
Constraints:
  - 红线：不改什么
Budget:
  - 重试上限
## Phase 1: Plan → Phase 2: Implement → Phase 3: Verify → Phase 4: Commit
```

`verify.txt`（5 字段格式）：

```
# 1. 文件存在
test: -f /path/to/file
# 2. 内容正确
grep: -q "expected" /path/to/file
# 3. 链式命令(用 bash: 前缀走 eval 保留 &&/||)
bash: cd /project && test -f data/x.db && echo "ok"
```

## 关键设计

- **worktree 隔离** — 任务从 `worker/{task_id}` 分支拉 worktree,执行完 merge 回主分支,编译失败保留 worktree 供调试
- **dead-watcher** — 启动时扫描 queue,僵尸任务(>30min executing)自动转 dead
- **escalate 升舱** — verify 失败时自动调新 claude 分析 + 改 prompt + 重投,最多 2 次
- **quality gate 门禁** — TRIVIAL_PASS 检测防止空 verify 文件绕过验收;标准门禁基线(git status/diff/docs/compile/build)自动追加到每次验收
- **lessons flywheel 学习飞轮** — 每次 exec 前注入 lessons.md,屡败履践,经验持续回灌
- **headless 模式** — web dashboard 投递时跳过 Terminal.app 弹窗,仅建 tmux 会话

## 文档

- `SKILL.md` — 加载到 Claude Code 的 skill 描述
- `qx-workflow.sh` — 执行引擎(bash,带行内注释解释每个设计决策)
- `lessons.md` — 历史踩坑经验(每次事故后追加)

## License

MIT
