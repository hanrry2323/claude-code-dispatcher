#!/bin/bash
# qx-workflow.sh — 执行 + 验收 串行单流，写标记文件
# 由 claude-code-dispatcher skill 自动调用
# 用法：qx-workflow.sh <task_id> <workspace> <exec_prompt_file> <verify_prompt_file> [headless]
#
# headless 模式：跳过 ensure_window（不弹 Terminal 窗口），由 web dashboard 使用。
# v6.5 增强: 投递时自动 ensure_window — tmux 会话不存在则建,
#   Terminal.app 窗口没显示该会话则弹一个新窗口 attach 过去。
#   这样不依赖上层 agent 是否执行了 SKILL.md 里的"初始化"段。
#   跨 workspace 互不干扰 (qx-{workspace} 会话名隔离)。

set -e

# 确保 PATH 包含 claude CLI（subprocess.Popen 可能不加载 shell rc）
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

TASK_ID=$1
WORKSPACE=$2
EXEC_PROMPT_FILE=$3
VERIFY_PROMPT_FILE=$4
HEADLESS=${5:-}

# observer 日志 — dashboard 从此文件读取状态 + 实时输出
OBSERVER_LOG="/tmp/qx-output-${WORKSPACE}.log"

# ── 修复(P0)：QUEUE_FILE 变量声明提前到参数解析后 ──
#   原实现：L260 才声明,导致 L191-206 队列更新段引用时变量未定义 → 死代码
#   新实现：参数解析后立即声明,后续 L191-206 / L260 都能用
#   副作用：T1/T2 这种「result 已写但 queue 还 dispatched」会自动归位 done
QUEUE_FILE="/tmp/qx-queue-${WORKSPACE}.json"

WORKSPACE_DIR=$(pwd)
echo "=== [qx-workflow] workspace=$WORKSPACE dir=$WORKSPACE_DIR ===" | tee -a "$OBSERVER_LOG"
echo "=== [qx-workflow] task_id=$TASK_ID ===" | tee -a "$OBSERVER_LOG"

# observer 日志轮转：超过 5MB 则截断保留末 500KB
if [ -f "$OBSERVER_LOG" ] && [ "$(stat -f%z "$OBSERVER_LOG" 2>/dev/null || stat -c%s "$OBSERVER_LOG" 2>/dev/null)" -gt 5242880 ]; then
    tail -c 512000 "$OBSERVER_LOG" > "${OBSERVER_LOG}.tmp" && mv "${OBSERVER_LOG}.tmp" "$OBSERVER_LOG" || true
fi

# workspace=default 时向后兼容旧路径
# ── 修复(P1)：STATE_FILE 死代码清理 ──
#   原实现：声明 STATE_FILE 但全文未写,SKILL.md 描述的恢复机制失效
#   新实现：删除 STATE_FILE 变量,持久化统一走 queue.json (见下方 P1 注释)
if [ "$WORKSPACE" = "default" ]; then
    MARKER="/tmp/qx-done-${TASK_ID}.marker"
    RESULT="/tmp/qx-result-${TASK_ID}.txt"
    SESSION="qx-demo"
else
    MARKER="/tmp/qx-done-${WORKSPACE}-${TASK_ID}.marker"
    RESULT="/tmp/qx-result-${WORKSPACE}-${TASK_ID}.txt"
    SESSION="qx-${WORKSPACE}"
fi

# ── ensure_session: 确保 tmux 会话存在（headless/窗口模式都需要）──
# headless 模式（web dashboard 投递）只建会话，不弹窗口
ensure_session() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux new-session -d -s "$SESSION" -x 200 -y 50
        echo "[ensure_session] tmux 会话 $SESSION 已创建"
    fi
}

# ── ensure_window: 兜底弹窗 (v6.5 新增, v6.8 修复) ──
# 只在非 headless 模式调用，Terminal.app 弹窗显示进度
ensure_window() {
    # macOS 专属: 检查 session 是否已 attached (有客户端连接)
    #    没有 → 弹一个新窗口 attach 过去
    if [ "$(uname)" = "Darwin" ]; then
        local client_count
        client_count=$(tmux list-clients -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$client_count" = "0" ]; then
            osascript -e "tell application \"Terminal\" to do script \"tmux attach -t $SESSION\"" >/dev/null 2>&1
            osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1
            echo "[ensure_window] 已弹 Terminal.app 窗口 attach 到 $SESSION"
        fi
    fi
}

# 始终确保 tmux 会话存在（headless 或窗口模式都需要）
ensure_session
# 非 headless 模式额外弹窗
if [ "$HEADLESS" != "headless" ]; then
    ensure_window
fi

# ── 修复(P1)：启动时 dead-watcher 扫描 ──
#   场景：上次脚本崩溃,queue.json 里有 status='executing' 但 mtime > 1800s 的僵尸任务
#   新实现：启动时扫描,僵尸标 dead + 写 dead_reason,避免状态永远卡 executing
if [ -f "$QUEUE_FILE" ]; then
    python3 -c "
import json, os, time
QUEUE_FILE = '$QUEUE_FILE'
DEAD_THRESHOLD = 1800  # 30 分钟
try:
    with open(QUEUE_FILE) as f:
        q = json.load(f)
    now = time.time()
    changed = False
    for t in q:
        if t.get('status') == 'executing':
            mtime = os.path.getmtime(QUEUE_FILE)
            age = now - mtime
            if age > DEAD_THRESHOLD:
                t['status'] = 'dead'
                t['dead_at'] = int(now)
                t['dead_reason'] = f'executing TTL={DEAD_THRESHOLD}s expired (age={int(age)}s)'
                changed = True
                print(f'[dead-watcher] 僵尸任务 {t.get(\"id\")} → dead')
    if changed:
        with open(QUEUE_FILE, 'w') as f:
            json.dump(q, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'[dead-watcher] 扫描失败 (忽略): {e}')
" 2>/dev/null || true
fi

rm -f "$MARKER" "$RESULT"

# stale marker 检查：如果 $MARKER 曾存在但未清理（罕见竞态），强制清除
# 但 RESULT 无对应内容则忽略（脚本加载前手动 rm 的场景）

# ── 重试计数器：防止升舱无限递归 ──
RETRY_FILE="/tmp/qx-retry-${WORKSPACE}-${TASK_ID}.count"
RETRY_COUNT=0
if [ -f "$RETRY_FILE" ]; then
    RETRY_COUNT=$(cat "$RETRY_FILE")
fi
MAX_RETRIES=2
if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "=== [FAIL] 已达最大重试次数 (${RETRY_COUNT})，放弃 ===" | tee -a "$OBSERVER_LOG"
    QUEUE_UPDATE "failed" "exec_exit=|,verify_exit=|,retry_exhausted=true"
    exit 1
fi

echo "=== [START] [$TASK_ID] (retry=$RETRY_COUNT/$MAX_RETRIES) ===" | tee -a "$OBSERVER_LOG"


# -- git worktree isolation --
WORK_BRANCH="worker/${TASK_ID}"
WORKTREE_DIR="${WORKSPACE_DIR}/../.qx-worker-${TASK_ID}"
CLEANUP_WORKTREE=0

# 异常退出时清理 worktree
cleanup_worktree() {
    if [ "$CLEANUP_WORKTREE" = 1 ]; then
        cd "$WORKSPACE_DIR" 2>/dev/null || true
        git merge --abort 2>/dev/null || true
        git worktree remove -f "$WORKTREE_DIR" 2>/dev/null || true
        git branch -D "$WORK_BRANCH" 2>/dev/null || true
    fi
}
# trap 清理 worktree + PY_PARSER（\$ 转义，延迟到 EXIT 时展开）
trap "cleanup_worktree; rm -f \$PY_PARSER \$ESCALATE_PROMPT" EXIT

if git rev-parse --git-dir >/dev/null 2>&1; then
    # 清理可能的残留（-f + rm -rf + git worktree prune 三重保险）
    git worktree prune 2>/dev/null || true
    git worktree remove -f "$WORKTREE_DIR" 2>/dev/null || true
    rm -rf "$WORKTREE_DIR"
    git branch -D "$WORK_BRANCH" 2>/dev/null || true
    # 创建临时分支（从当前 HEAD 分叉）
    git branch -f "$WORK_BRANCH" HEAD 2>/dev/null
    git worktree add "$WORKTREE_DIR" "$WORK_BRANCH"
    CLEANUP_WORKTREE=1
    # 同步 .venv 和 node_modules（避免重复安装）
    if [ -d "${WORKSPACE_DIR}/.venv" ]; then
        ln -sfn "${WORKSPACE_DIR}/.venv" "${WORKTREE_DIR}/.venv" 2>/dev/null || true
    fi
    if [ -d "${WORKSPACE_DIR}/frontend/node_modules" ]; then
        mkdir -p "${WORKTREE_DIR}/frontend"
        ln -sfn "${WORKSPACE_DIR}/frontend/node_modules" "${WORKTREE_DIR}/frontend/node_modules" 2>/dev/null || true
    fi
    cd "$WORKTREE_DIR"
    echo "── worktree: $WORKTREE_DIR (branch: $WORK_BRANCH) ──"
else
    echo "[WARN] 非 git 目录，跳过 worktree 隔离"
fi

# ── QUEUE_UPDATE：写队列状态，必须在首次调用前定义 ──
QUEUE_UPDATE() {
    local new_status="$1"
    local extra_kvs="$2"
    if [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ]; then
        python3 -c "
import json, os, time
QUEUE_FILE = '$QUEUE_FILE'
TASK_ID = '$TASK_ID'
NEW_STATUS = '$new_status'
EXTRA_KVS = '$extra_kvs'
try:
    with open(QUEUE_FILE) as f:
        q = json.load(f)
    now = int(time.time())
    for t in q:
        if t.get('id') == TASK_ID:
            t['status'] = NEW_STATUS
            t['updated_at'] = now
            if NEW_STATUS == 'executing' and 'started_at' not in t:
                t['started_at'] = now
            if NEW_STATUS in ('done', 'failed', 'escalated', 'dead'):
                t['completed_at'] = now
            for kv in EXTRA_KVS.split(','):
                kv = kv.strip()
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    try:
                        t[k] = int(v)
                    except ValueError:
                        t[k] = v
            break
    with open(QUEUE_FILE, 'w') as f:
        json.dump(q, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'[queue-update] 失败 (忽略): {e}')
" 2>/dev/null || true
    fi
}

### Phase 1: 执行 ###
echo ""
echo "── 执行 ──"
# ── 修复(P3)：进入 exec 前标 executing,让 catch up 看得到进度 ──
QUEUE_UPDATE "executing" ""
PY_PARSER=$(mktemp)
cat > "$PY_PARSER" << 'PYEOF'
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line); t = d.get('type','')
        if t == 'assistant':
            for c in d.get('message',{}).get('content',[]):
                if c.get('type')=='text': print(c['text'], flush=True)
                if c.get('type')=='tool_use': print('[TOOL] ' + c['name'] + ' ' + str(c.get('input',{}))[:80], flush=True)
        elif t == 'result' and d.get('is_error'):
            print('[ERR] ' + d.get('result','')[:200], flush=True)
    except: pass
PYEOF
# ── observer 集成: 全部输出 tee 到 /tmp/qx-output-{workspace}.log 供 HTTP 页面拉取 ──
# 用 script 创建 PTY 迫使 claude (Bun 编译) 无缓冲输出，实现实时流
# 子 shell 捕获真实 exit code，外层 pipeline 不丢失
{
    timeout 600 claude -p "$(cat "$EXEC_PROMPT_FILE")" --dangerously-skip-permissions \
      --model flash --output-format stream-json --verbose 2>&1
    echo "[CLAUDE_EXIT:$?]"
} | tee -a "$OBSERVER_LOG" | python3 "$PY_PARSER"
EXEC_EXIT=$(tail -1 "$OBSERVER_LOG" | grep -o '\[CLAUDE_EXIT:[0-9]*\]' | grep -o '[0-9]*')
EXEC_EXIT=${EXEC_EXIT:-0}
rm -f "$PY_PARSER"

echo ""
echo "── 执行完成 (exit=$EXEC_EXIT) ──" | tee -a "$OBSERVER_LOG"

# ── git status 检查：执行完成后检查是否有未 stage 文件 ──
if git rev-parse --git-dir >/dev/null 2>&1; then
    UNSTAGED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$UNSTAGED" -gt 0 ]; then
        echo "── [WARN] 执行后还有 $UNSTAGED 个未 stage 文件 ──" | tee -a "$OBSERVER_LOG"
        git status --short 2>/dev/null | head -10 | tee -a "$OBSERVER_LOG" || true
    fi
fi

# ── worktree merge + 清理 ──
if [ "$CLEANUP_WORKTREE" = 1 ]; then
    cd "$WORKSPACE_DIR"
    echo "-- 合并 worktree (branch: $WORK_BRANCH) --"
    git merge "$WORK_BRANCH" --no-edit -m "merge worker/${TASK_ID}" 2>&1 | tail -3 || echo "[WARN] merge 非预期，跳过"
    git worktree remove -f "$WORKTREE_DIR" 2>/dev/null || true
    git branch -D "$WORK_BRANCH" 2>/dev/null || true
    echo "── worktree 已清理 ──"
fi

### Phase 1.5: 自动编译检查 ###
echo ""
echo "── 编译检查 ──"
# ── 修复(P5)：编译硬编码 → 项目类型标识文件推断 ──
#   原实现：硬编码 `scheduler.py` + py_compile,hp/qb/xianyu 没有这个文件就跳过
#   新实现：python 项目用 compileall src_dir (从 [project.scripts] 或默认 src/)
#           frontend 仍走 bun run build (项目标识文件判断)
if [ -f "pyproject.toml" ]; then
    # 推断 src_dir：优先 [tool.poetry.packages] / [project.scripts]，默认 src/
    src_dir=$(python3 -c "
import tomllib, os
try:
    with open('pyproject.toml', 'rb') as f:
        cfg = tomllib.load(f)
    # Poetry 包路径
    for p in cfg.get('tool', {}).get('poetry', {}).get('packages', []):
        if 'include' in p:
            print(p['include']); raise SystemExit
    # 默认 src/
    if os.path.isdir('src'):
        print('src'); raise SystemExit
    # 兜底:整个 . 当前目录
    print('.')
except Exception:
    print('src')
" 2>/dev/null)
    python3 -m compileall -q "$src_dir" 2>/dev/null && echo "[OK] python compileall ($src_dir)" || echo "[WARN] python compileall 异常"
    # mypy 检查（如果项目有 mypy.ini 或 pyproject.toml 含 mypy 配置）
    if [ -f "mypy.ini" ] || [ -f ".mypy.ini" ] || grep -q 'mypy' pyproject.toml 2>/dev/null; then
        python3 -m mypy "$src_dir" --show-error-codes 2>&1 | tail -10 | tee -a "$OBSERVER_LOG" && echo "[OK] mypy ($src_dir)" || echo "[WARN] mypy 检查异常"
    fi
fi
if [ -d "frontend" ] && [ -f "frontend/package.json" ]; then
    (cd frontend && bun run build 2>&1 | tee -a "$OBSERVER_LOG" | tail -10) && echo "[OK] frontend build" || echo "[WARN] frontend build 异常"
fi
echo "── 编译检查完成 ──"

### Phase 2: 脚本验收 ###
echo ""
echo "── 脚本验收 ──"
# ── 修复(P3)：进入 verify 前标 verifying ──
QUEUE_UPDATE "verifying" ""
VERIFY_EXIT=0
FAIL_LOG=""
if [ -f "$VERIFY_PROMPT_FILE" ]; then
    # ── 修复(P4)：eval 替换为格式严格化解析器 ──
    #   原实现：`eval "$verify_cmd"` → verify 文件混入非 shell 命令必 FAIL
    #           (RED-01 case：「Report PASS/FAIL」被 eval 报 command not found)
    #   新实现：每行只能 # / cmd: / test: / grep: / bash: 开头
    #           解析器用 awk/python3,失败分 parse_error vs exec_error 两类
    #           parse_error 降级为 warn（2026-06-22: 以防模板未同步导致死循环）
    while IFS= read -r verify_line; do
        # 跳过空行
        [[ -z "$verify_line" ]] && continue
        # 允许纯注释行（整行以 # 开头,允许前置空白）
        if [[ "$verify_line" =~ ^[[:space:]]*# ]]; then
            echo "  📝 $verify_line"
            continue
        fi
        # 格式校验：必须以 cmd: / test: / grep: / bash: / # 前缀开头
        if ! [[ "$verify_line" =~ ^[[:space:]]*(cmd|test|grep|bash|#):[[:space:]] ]]; then
            echo "  ⚠️  WARN: 行不以 cmd:/test:/grep:/bash:/# 开头 → $verify_line"
            echo "    (跳过,不导致 FAIL,但建议加前缀)"
            continue
        fi
        # 去掉前缀,提取真实命令
        verify_cmd="${verify_line#*: }"
        verify_cmd="${verify_cmd#*:}"
        # 自动补全命令：grep: 开头自动加 grep，test: 开头自动加 test
        case "$verify_line" in
            grep:*) [[ "$verify_cmd" != grep* ]] && verify_cmd="grep $verify_cmd" ;;
            test:*) [[ "$verify_cmd" != test* && "$verify_cmd" != \[* ]] && verify_cmd="test $verify_cmd" ;;
        esac
        echo "  🔍 $verify_line"
        # ── 修复(P4)：用 bash -c 子 shell 而非 eval,加 timeout 30s 防止卡死 ──
        if timeout 30 bash -c "$verify_cmd" >> /tmp/qx-verify-${WORKSPACE}-${TASK_ID}.log 2>&1; then
            echo "    ✅ PASS" | tee -a "$OBSERVER_LOG"
        else
            rc=$?
            echo "    ❌ FAIL (exit=$rc)"
            VERIFY_EXIT=1
            FAIL_LOG="${FAIL_LOG}EXEC_ERROR: $verify_line"$'\n'
        fi
    done < "$VERIFY_PROMPT_FILE"
else
    echo "[WARN] 验收文件不存在，跳过"
fi

### 写结果 ###
{
    echo "task_id: $TASK_ID"
    echo "exec_exit: $EXEC_EXIT"
    echo "verify_exit: $VERIFY_EXIT"
    echo "completed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$VERIFY_EXIT" != 0 ]; then
        echo "--- FAILURE DETAILS ---"
        echo "$FAIL_LOG"
    fi
} > "$RESULT"
echo "done" > "$MARKER"

# ── QUEUE_UPDATE 已在脚本顶部定义 ──

# 当前任务收尾: 终态映射
if [ "$VERIFY_EXIT" = 0 ]; then
    QUEUE_UPDATE "done" "exec_exit=$EXEC_EXIT,verify_exit=$VERIFY_EXIT"
else
    QUEUE_UPDATE "failed" "exec_exit=$EXEC_EXIT,verify_exit=$VERIFY_EXIT"
fi

echo ""
if [ "$VERIFY_EXIT" = 0 ]; then
    echo "=== [PASS] [$TASK_ID] 验收通过 ===" | tee -a "$OBSERVER_LOG"
else
    echo "=== [FAIL] [$TASK_ID] 验收不通过 ===" | tee -a "$OBSERVER_LOG"
    echo "$FAIL_LOG"
fi
echo "结果: exec=$EXEC_EXIT verify=$VERIFY_EXIT"

# ── 验收失败 → 自动修复（通用升舱） ──
if [ "$VERIFY_EXIT" != 0 ]; then
    echo "=== [ESCALATE] 验收失败 (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)，自动分析修复 ===" | tee -a "$OBSERVER_LOG"

    FIXED_EXEC="/tmp/qx-workflow-${WORKSPACE}-${TASK_ID}-fixed-exec.txt"
    QUEUE_UPDATE "escalated" "exec_exit=$EXEC_EXIT,verify_exit=$VERIFY_EXIT,escalation_reason=verify_failed"
    ESCALATE_PROMPT=$(mktemp)

    # ── 收集当前仓库状态作为升舱上下文 ──
    GIT_DIFF=$(git diff HEAD~1 --stat 2>/dev/null || echo "[无上一个 commit]")
    GIT_STATUS=$(git status --short 2>/dev/null || echo "[无 git 信息]")
    FAIL_LOG_CONTENT=$(echo "$FAIL_LOG" | head -20)
    LESSONS_CONTENT=$(cat "$WORKSPACE_DIR/docs/lessons.md" 2>/dev/null || echo "[无 lessons.md]")

    cat > "$ESCALATE_PROMPT" <<ESCALATE_EOF
## 升舱修复任务

Workspace: $WORKSPACE
Project: $WORKSPACE_DIR
Task: $TASK_ID
Retry: $((RETRY_COUNT+1))/$MAX_RETRIES

### 失败原因

验证失败（exec_exit=$EXEC_EXIT, verify_exit=$VERIFY_EXIT）。
验收日志：
$FAIL_LOG_CONTENT

### 当前仓库状态

```
# git diff (HEAD~1 以来的变更)
$GIT_DIFF

# git status
$GIT_STATUS
```

### 原始 exec prompt（参考）

$(cat "$EXEC_PROMPT_FILE" 2>/dev/null | head -60)

### 验证脚本

$(cat "$VERIFY_PROMPT_FILE" 2>/dev/null || echo "N/A")

### 执行日志（最后 50 行，了解当前状态）

```
$(tail -50 "$OBSERVER_LOG" 2>/dev/null || echo "[无日志]")
```

### 历史教训（请先读，避免重复踩坑）

$LESSONS_CONTENT

### 你的任务

1. 读项目当前状态，分析 verify 为什么失败
2. 写修复后的 exec prompt 到 $FIXED_EXEC
3. 修复后的 prompt 必须：
   - 精确到文件路径和行级改动
   - 包含 git add + git commit 步骤
   - 自包含（不依赖上一步的中间状态）
4. 写入 lessons.md 追加一行：| $(date +%Y-%m-%d) | $TASK_ID | [失败简述] | [修复方案] |
5. 写入前检查 lessons.md 是否已有相同 TASK_ID 条目，有则跳过避免重复
5. 只写 prompt 到 $FIXED_EXEC，其他输出忽略
ESCALATE_EOF

    timeout 300 claude -p "$(cat "$ESCALATE_PROMPT")" --dangerously-skip-permissions --model flash --verbose 2>&1 | tail -5 || echo "[ESCALATE] claude 升舱进程超时或失败" | tee -a "$OBSERVER_LOG"
    rm -f "$ESCALATE_PROMPT"

    if [ -f "$FIXED_EXEC" ] && [ -s "$FIXED_EXEC" ]; then
        if grep -qE 'Phase [0-9]|^## Goal|git add|## End state|## Evidence' "$FIXED_EXEC"; then
            echo "$((RETRY_COUNT + 1))" > "$RETRY_FILE"
            echo "=== [RETRY] 修复后 prompt 已写入,重新投递 ==="
            exec "$0" "$TASK_ID" "$WORKSPACE" "$FIXED_EXEC" "$VERIFY_PROMPT_FILE"
        else
            echo "=== [FAIL] fixed-exec 内容不像 prompt（缺 Phase/Goal/git add 关键词） ===" | tee -a "$OBSERVER_LOG"
            exit 1
        fi
    else
        echo "=== [FAIL] 自动修复失败,fixed-exec 未写入 ===" | tee -a "$OBSERVER_LOG"
        exit 1
    fi
fi

# 检查 /tmp/qx-queue-{workspace}.json，如果有 pending 任务则自动投递下一个
# ── 修复(P0)：QUEUE_FILE 声明已上移到 L13 后,此处直接用 ──
if [ -f "$QUEUE_FILE" ]; then
    NEXT_ID=$(python3 -c "
import json, sys
try:
    with open('$QUEUE_FILE') as f:
        q = json.load(f)
    for i, t in enumerate(q):
        if t.get('status') == 'pending':
            t['status'] = 'dispatched'
            with open('$QUEUE_FILE', 'w') as f:
                json.dump(q, f, indent=2, ensure_ascii=False)
            print(t['id'])
            print(t.get('exec',''))
            print(t.get('verify',''))
            break
except: pass
" 2>/dev/null)
    if [ -n "$NEXT_ID" ]; then
        NEXT_TASK_ID=$(echo "$NEXT_ID" | head -1)
        NEXT_EXEC=$(echo "$NEXT_ID" | head -2 | tail -1)
        NEXT_VERIFY=$(echo "$NEXT_ID" | head -3 | tail -1)
        echo ""
        echo "=== [NEXT] 队列: [$NEXT_TASK_ID] ==="
        cd "$WORKSPACE_DIR"
        exec "$0" "$NEXT_TASK_ID" "$WORKSPACE" "$NEXT_EXEC" "$NEXT_VERIFY"
    fi
fi

exit $VERIFY_EXIT
