---
name: claude-code-dispatcher
description: >-
  Plan-and-dispatch workflow: user discusses requirements in the dialog,
  writes structured instructions, dispatches to Claude Code in a persistent
  tmux session for execution + verification, captures results via marker
  files, and reports back. Survives restarts.
---

# Claude Code Dispatcher · 持久化闭环工作流

## ⚠️ 边界声明（Boundary Declaration · 2026-06-23）

**本 skill 是通用 dispatcher，独立于任何项目。**

| 归属 | 路径 | 性质 |
|---|---|---|
| **claude-code-dispatcher skill** | `~/.claude/skills/claude-code-dispatcher/` | 本 skill 唯一权威源 |
| **task-dispatcher skill** | `~/.claude/skills/task-dispatcher/` | 本 skill 的镜像（薄壳合并版） |
| **qx-workflow.sh** | `claude-code-dispatcher/qx-workflow.sh` | 本 skill 的执行引擎 |
| **qx-observer / qxo** | `~/program/qx-observer/` | **消费者之一**，不是 dispatcher 的归属方 |

### ❌ 历史上曾被 AI agent 错误归入其它项目的痕迹（已清理）

以下文件已在本轮清理中全部删除：

1. ~~`~/program/qx-observer/scripts/qx-dispatcher.py`~~ — 试图把 dispatcher 列为 qxo 的子模块（已删）
2. ~~`~/program/qx-observer/docs/skill-dispatcher.md`~~ — 把 dispatcher 设计文档搬到 qxo 仓库（已删）
3. ~~`~/program/qx-observer/app/core/loop/runner.py`~~ — 用 Python 重写 qx-workflow.sh 试图吞并 skill（已删）
4. ~~`~/program/qx-observer/qx-workflow.sh`~~ — 项目根的薄壳副本（已删）
5. ~~`~/program/qx-observer/scripts/qx-workflow.sh`~~ — scripts 目录的薄壳副本（已删）

以下已修复（保留但不再违规）：
6. `~/program/qx-observer/app/api/dispatcher.py` — 只读读取 dispatcher state，默认 workspace `"qxo"` → `"default"`
7. SKILL.md 示例默认 workspace `"qxo"` → 通用示例名（已修正）
8. `~/.claude/CLAUDE.md` 旧描述（已修正）
9. `~/.agents/skills/` 与 `~/.claude/skills/` 已同步

### 🚫 防污染承诺（不可变）

- **qx-observer 的源码（V7/V8 系列）属于 qxo 项目功能，不属于 dispatcher**
- **qx-qxo tmux 会话 / qxo 日志 / qxo 任务文件全部隔离，dispatcher 不应干预其内容**
- **任何"把 dispatcher 功能挪进 qxo 项目"的尝试 = 污染，应立即回退**
- **dispatcher 的改进必须发生在 `~/.claude/skills/claude-code-dispatcher/` 内，禁止在消费者项目里改 dispatcher**

---

## 核心设计

多窗口并行，每窗独立。资源按 workspace 隔离：

```
磁盘文件（跨会话持久）               tmux 会话（持久窗口）
  /tmp/qx-state-{workspace}.json        qx-{workspace}
  /tmp/qx-done-{workspace}-{id}.marker  一个窗口，一直滚动
  /tmp/qx-result-{workspace}-{id}.txt
  /tmp/qx-workflow-{workspace}-{id}-exec.txt
  /tmp/qx-workflow-{workspace}-{id}-verify.txt
```

workspace 自动检测（优先级）：
1. 环境变量 `QX_WORKSPACE`（显式指定）
2. 当前工作目录匹配已知项目
3. 默认 `default`

workspace 为 `default` 时向后兼容旧路径（`/tmp/qx-state.json`、`qx-demo`）。

### 项目目录

脚本自动使用当前工作目录。投递前 cd 到项目目录即可，无需配置映射。

任何 session 加载 skill 后都能恢复同 workspace 的任务状态。

## 初始化（skill 加载时自动执行）

### workspace 检测

当前工作目录的目录名即为 workspace。你 cd 到任何项目目录，加载 skill 后自动使用项目名作为 workspace。

```python
import os
from pathlib import Path

# 按优先级检测 workspace
QX_WORKSPACE = os.environ.get("QX_WORKSPACE")
if not QX_WORKSPACE:
    # 直接用当前目录名作为 workspace（无需映射表，任何项目都行）
    QX_WORKSPACE = Path.cwd().name.lower().replace(" ", "-")
    if not QX_WORKSPACE:
        QX_WORKSPACE = "default"

SESSION = f"qx-{QX_WORKSPACE}"
STATE_FILE = f"/tmp/qx-state-{QX_WORKSPACE}.json"
```

注意：向后兼容意味着 workspace=default 时 state 文件和 tmux 会话名与旧版完全一致，已有数据不丢失。

### 恢复状态 + 重建 tmux

```python
# 1. 恢复状态
state = {}
if os.path.exists(STATE_FILE):
    state = json.loads(open(STATE_FILE).read())

# 2. 检查 tmux 会话
tmux_alive = subprocess.run(
    ["tmux", "has-session", "-t", SESSION],
    capture_output=True
).returncode == 0

if not tmux_alive:
    import subprocess, osascript
    tmux new-session -d -s SESSION -x 150 -y 40
    open -a Terminal
    osascript -e f'tell app "Terminal" to do script "tmux attach -t {SESSION}"'

# 3. 检查是否有未完成任务
unfinished = [t for t in state.get("tasks", []) if t["status"] in ("dispatched", "executing", "verifying")]
```

## 状态文件格式

```json
{
  "workspace": "demo-project",
  "tmux_session": "qx-demo-project",
  "created_at": "2026-06-17T15:00:00Z",
  "tasks": [
    {
      "id": "V0.33",
      "title": "修复某某功能",
      "status": "done",
      "exec_exit": 0,
      "verify_exit": 0,
      "started_at": "2026-06-17T15:01:00Z",
      "completed_at": "2026-06-17T15:03:00Z"
    }
  ]
}
```

状态流转：`dispatched → executing → verifying → done | failed`

## 核心流程

### Phase 1: 规划（对话框）

你在对话框里讨论需求、确定方案、写指令文件。

### Phase 2: 写指令 + 准备 prompt

写指令文件到 `instructions/v020/V0.XX-NAME.md`。
同时生成两个 prompt 文件（给后台 claude 用），文件路径带上 workspace 前缀。

**单任务模式（快速修复/小改动）：**

```bash
cat > /tmp/qx-workflow-{workspace}-V0.XX-exec.txt << 'EOF'
Read docs/lessons.md for relevant lessons, then read instructions/active/V0.XX-NAME.md and execute it.
Follow the acceptance criteria exactly.

BEFORE writing any code (Phase 2): 调 `code-review-graph detect-changes --base HEAD~1 --brief` 看 blast radius.
  - 记录 risk score / changed functions / test gaps 到 plan.
  - 改 1 个函数连带 >5 文件 → 重新评估方案, 把连带文件加入 commit 列表.

After implementation:
1. Run project tests (pytest / bun run build / tsc)
2. Run `code-review-graph detect-changes --base HEAD~1 --brief` 二次确认:
   - risk score 反映在 commit message
   - test gap 中标的函数必须补单测或显式说明豁免理由
3. Update STATUS.md (add completed task, update test counts)
4. Update MEMORY.md (key decisions)
5. Update CHANGELOG.md (append entry)
6. Update BACKLOG.md (mark done)
7. git add + commit (only relevant files, 连带文件必须含)
EOF

cat > /tmp/qx-workflow-{workspace}-V0.XX-verify.txt << 'EOF'
# 按指令文件验收标准逐条检查。非命令行用 # 开头（解析器跳过）。
# 验收项示例（按实际需求替换命令）：
test: cd /tmp/test-run && pytest --tb=short -x
grep: grep -q "target value" config/settings.py
bash: git status --porcelain | grep -v '^\?\?' | cat && echo "---"
# git status & docs 更新检查
bash: git status --porcelain | awk '/^[^?]/{print $2}' | grep -c -E '(STATUS|MEMORY|CHANGELOG).*\.md' || echo "WARN: 文档未更新"
cmd: test -z "$(git status --porcelain | grep -v '^\?\?')" && echo "clean"
EOF
```

**批量模式（多个任务/大功能 — 推荐）：**

exec prompt 写三段式，让 Claude Code 自规划→自开发→自验收：

```bash
cat > /tmp/qx-workflow-{workspace}-{batch_id}-exec.txt << 'EOF'
## Goal

End state:
  （验收时必须成立的条件）

Evidence:
  （验收脚本命令，每条 exit 0 = PASS）

Constraints:
  （红线：不改什么、不引入什么、不动什么）

Budget:
  （最多尝试次数，超限后行为）

## Phase 1: Plan
先读 docs/lessons.md 中跟当前任务相关的教训，再读所有指令文件和相关源码。

**进度标记**：每步完成时打印 `=== [进度] N/M ===` 标记，让窗口一直有输出。

**Phase 1.5: Blast Radius（必须）**
调 `code-review-graph detect-changes --base HEAD~1 --brief` 看 blast radius:
  - 记录 risk score / changed functions / test gaps / affected flows
  - 改 1 个函数连带 >5 文件 → 重新评估方案, 把连带文件加入 commit 列表
  - test gap 列出的函数必须规划补测或显式豁免理由

## Phase 2: Implement
按方案逐步实现，每步验证语法/编译。

## Phase 3: Test & Document
- 跑项目测试（pytest / bun run build / tsc）
- 二次跑 `code-review-graph detect-changes --base HEAD~1 --brief`:
  - risk score / test gap 反映在 commit message 或 commit body
  - 补测或豁免理由已写入 commit body
- 更新 STATUS.md（测试状态、已完成任务）
- 更新 MEMORY.md（关键决策、架构变更）
- 更新 CHANGELOG.md（按规范追加条目）
- 更新 BACKLOG.md（完成项标记）

## Phase 4: Commit
- `git add` 只 stage 相关文件（含 graph 提示的连带文件）
- 按项目 commit 规范写 message，risk score 写进 commit body
- 不 commit .env / 密钥 / 无关文件

## Phase 5: Self-Verify
跑验收命令，报告 PASS/FAIL。
EOF

cat > /tmp/qx-workflow-{workspace}-{batch_id}-verify.txt << 'EOF'
# 终审视角验收。注释行以 # 开头，验收命令必须前缀。
# 按实际任务替换下面的示例命令：

# 1. 文件变更检查
bash: git diff --name-only HEAD~1 | sort | uniq
# 2. 编译/语法检查
cmd: python -c "import ast; ast.parse(open('$(git diff --name-only HEAD~1 | head -1)').read())"
# 3. 项目测试
test: cd /tmp/test-run && python -m pytest -x --tb=short 2>&1 | tail -5
# 4. docs 更新
grep: -E '(STATUS|CHANGELOG).*updated' CHANGELOG.md
# 5. git status
bash: git status --porcelain | awk '/^[^?]/{print $2}' | grep -c . || echo "clean"
# 6. 项目特有检查（按需追加）
# test: ...
EOF
```

### Phase 3: 投递（非阻塞）

**单任务模式：**

先 cd 到项目目录，再投递：

```bash
SCRIPT=$HOME/.agents/skills/claude-code-dispatcher/qx-workflow.sh
tmux send-keys -t qx-{workspace} "cd $(pwd) && \
  $SCRIPT V0.XX {workspace} \
  /tmp/qx-workflow-{workspace}-V0.XX-exec.txt \
  /tmp/qx-workflow-{workspace}-V0.XX-verify.txt" Enter
```

**批量模式（推荐）：** 一次投多个指令文件，Claude Code 自主规划执行。

```bash
SCRIPT=$HOME/.agents/skills/claude-code-dispatcher/qx-workflow.sh
BATCH_ID="V0.XX-V0.YY"
tmux send-keys -t qx-{workspace} "cd $(pwd) && \
  $SCRIPT $BATCH_ID {workspace} \
  /tmp/qx-workflow-{workspace}-$BATCH_ID-exec.txt \
  /tmp/qx-workflow-{workspace}-$BATCH_ID-verify.txt" Enter
```

同时更新 state.json：

```json
{
  "workspace": "...",
  "id": "V0.XX",
  "title": "...",
  "status": "dispatched",
  "started_at": "..."
}
```

投完立刻回复用户："已投递 V0.XX，完成后自动验收并汇总。" 不阻塞。

### Phase 4: 检测（每次用户发消息时自动执行）

```python
# 每次回复前的自动检查
def check_pending_tasks(state, workspace):
    for task in state["tasks"]:
        if task["status"] in ("dispatched", "executing", "verifying"):
            marker = f"/tmp/qx-done-{workspace}-{task['id']}.marker"
            if os.path.exists(marker):
                task["status"] = "done"
                result = open(f"/tmp/qx-result-{workspace}-{task['id']}.txt").read()
                task["exec_exit"] = extract_exit_code(result)
                task["verify_exit"] = extract_verify_code(result)
                task["completed_at"] = now()
                save_state()
                return task
    return None
```

如果检测到新完成的任务，在回复末尾追加汇总。

### Phase 5: 汇总

**单任务：**

```markdown
**V0.XX 完成**

执行: ✅ exit=0
验收: ✅ 4/4 PASS (或失败详情)

继续下一轮还是修？
```

**批量：**

```markdown
**V0.XX-V0.YY 批量完成**

执行: ✅ exit=0
验收: ✅ 全部通过 (或失败详情)

Claude Code 自规划→开发→验收全流程跑完。
需要我终审还是继续下个任务？
```

## 窗口管理 (v6.5: 由 qx-workflow.sh 兜底, 不依赖上层 agent 自觉)

**`qx-workflow.sh` 在每次投递时自动调用 `ensure_window()`**:
1. 检查 tmux 会话 `qx-{workspace}` 是否存在, 不存在则建 (`tmux new-session -d`)
2. macOS 上: 查 Terminal.app 是否有窗口正在显示该会话的 tty
3. 没有 → 弹一个新窗口, `tmux attach -t qx-{workspace}`

这样**不依赖上层 agent 是否执行了 SKILL.md 里的"初始化"段** —— 任何调 `qx-workflow.sh` 的入口 (agent / 手动 / 其他脚本) 都自动触发窗口弹出。上层 agent 不需要自己写 `osascript` 兜底。

| 步骤 | 由谁做 | 命令 |
|------|--------|------|
| 检查/创建 tmux 会话 | **qx-workflow.sh** | `ensure_window()` 内部 |
| 弹 Terminal.app 窗口 | **qx-workflow.sh** | `osascript ... do script "tmux attach -t ..."` |
| 拉前台 (activate) | **qx-workflow.sh** | `osascript ... activate` |
| 用户 detach | 用户操作 | `Ctrl+B d` (不关窗口) |
| 再次 attach | 用户操作 | `tmux attach -t {session}` |

**跨 workspace 隔离**: `qx-{workspace}` 会话名天然隔离, 多任务并发不互相覆盖。

## 指令标准

- **Goal 合同格式**：exec prompt 用四字段（End state / Evidence / Constraints / Budget），Evidence 字段就是验收脚本命令
- **学习飞轮**：每个任务前先读 `docs/lessons.md`；验收失败后升舱 Claude 自动追加新教训

## 红线

- 所有状态存磁盘 `/tmp/qx-state-{workspace}.json`，不依赖当前 session 内存
- workspace=default 时向后兼容 `/tmp/qx-state.json`
- 投递用 `tmux send-keys -t qx-{workspace}`（非阻塞），永远不用 `&&` 串行执行
- 不轮询：只在你每次发消息时检查标记文件
- 不键盘模拟（keystroke）投中文
- **同一 workspace 内串行执行**（不同 workspace 互不阻塞）
- prompt 文件存 `/tmp/`，不写项目中
- 每次初始化时如果 tmux 不存在，自动重建 + 开 Terminal
- **优先用批量模式**：多个关联任务一次性投，让 Claude Code 自规划→自开发→自验收
- **验收失败不重试，直接升舱**：`qx-workflow.sh` 在 verify 失败后自动拉新 Claude 分析 + 修 prompt + 重投（逻辑在脚本中，不依赖上层 agent 响应）

## 验收

| # | 验收 | 方法 |
|---|------|------|
| 1 | skill 加载后自动恢复状态 | 读 /tmp/qx-state-{workspace}.json 并汇报 |
| 2 | tmux 窗口自动打开 | `open -a Terminal` + `tmux attach -t qx-{workspace}` |
| 3 | 投递不阻塞对话框 | 投完立即回复 |
| 4 | 下次消息自动检测完成 | 回复中附带完成汇总 |
| 5 | 重启不丢任务 | 新 session 加载 skill 后识别 unfinished |
| 6 | 多窗口互不干扰 | 同时投递不同 workspace，各自完成各自验收 |
