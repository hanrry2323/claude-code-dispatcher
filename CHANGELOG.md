# Changelog

## v0.2.0 (2026-06-23)

### Quality Gate
- TRIVIAL_PASS: empty/comment-only verify files now correctly FAIL instead of silently PASS
- Standard verify auto-generation (git status, git diff, docs check, compile, build)
- Fallback verify when user file missing (uses auto-generated baseline)
- Result summary appended to observer log for capture-pane detection
- Verify file dedup: auto-generated checks only appended once

### Escalation Fix
- P9: escalation claude output pipe `| tail -5 || echo` silently swallowed claude failures (tail -5 always exit 0). Replaced with `tee -a "$OBSERVER_LOG"` + `PIPESTATUS[0]` capture
- Escalated marker written at all 3 exhaustion exit points (retry exhaustion, bad fixed-exec, no fixed-exec)

### Lessons Flywheel
- Phase 2 instructions now mandate `cat docs/lessons.md` before writing exec prompt
- Escalation auto-fix includes lessons analysis for continuous improvement loop

### Documentation
- SKILL.md Phase 4: Python pseudo-code → executable bash commands with result templates
- SKILL.md Phase 5: Split into PASS/FAIL templates for clear reporting

## v0.1.0 (2026-06-23)

### 起源
claude-code-dispatcher 从 qx-observer 抽出,成为独立项目。最初是 qxo 内部 tmux 后台任务调度机制,经历了 6 个月演化(从 bash 薄壳到 5 阶段 Loop 引擎),沉淀了大量设计经验,值得独立仓库版本化。

### 重构
- 项目迁出 qxo 主仓库 → `~/program/claude-code-dispatcher/`
- 三副本(skill 加载路径)统一为 symlink,避免漂移
- 边界声明文档化:`SKILL.md` 头部声明 dispatcher 与 qxo 互相隔离

### 修复
- P0: 队列文件变量声明提前到参数解析后
- P1: 删除 STATE_FILE 死代码,持久化统一走 queue.json
- P2: PYTHONPATH 与 PATH 导出(确保 claude CLI 可用)
- P3: 执行/验收前先标 executing/verifying 状态
- P4: verify 解析器 `eval` → 格式严格化 + `bash -c` + timeout 30s
- P5: 编译检查从硬编码 scheduler.py 改为按 pyproject.toml 推断 src_dir
- P6: trap 清理 worktree + PY_PARSER + ESCALATE_PROMPT
- P7: verify `bash:` 前缀走 eval 保留 && 链式语义
- P8: escalate prompt 减噪 — diff/status/log 全部加 head/tail 限制

### 优化
- OBSERVER_LOG 5MB 截断
- escalate claude 进程加 timeout 300s
- 验收输出 PASS 去重
- escalate prompt 增加 `obs 日志 tail` + `git log -5` 上下文
