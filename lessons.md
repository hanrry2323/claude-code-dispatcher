# Lessons · claude-code-dispatcher

按时间倒序。每条包含 root cause + fix + impact。

| 日期 | 问题 | 根因 + 修复 |
|------|------|-------------|
| 2026-06-23 | verify bash: 链式命令被截断 | 解析器对所有行走 `bash -c`,`grep -q X && echo Y` 在 X 命中时 echo 不执行,verify 看不到"Y 已 echo"。`bash:` 前缀改走 `eval`,保留 `&&` / `\|\|` 链式语义 |
| 2026-06-23 | escalate prompt 含太多历史噪音 | git diff HEAD~1 + log 全量 + obs 日志无界 + lessons 全量 → 单次 escalate 上万 token,Claude 上下文拥挤导致二次决策质量差。修复：diff 限 HEAD vs worktree (head 30 行) + status head 20 行 + log 限最近 5 commit + obs tail 100 行 + lessons tail 50 行 |
| 2026-06-23 | escalate 反引号/$() 被 bash 提前求值 | 老的 `$GIT_DIFF` 等嵌入 here-doc 后,bash 在生成 prompt 时先求值,会把原始 diff 输出替换成"git diff 执行结果"嵌进 prompt(更糟的是某些变量如 `$(date)` 会被替换成执行时间,导致 prompt 含外部副作用)。修复：用 escape 范围限定,变量在 prompt 里仍是变量 |
| 2026-06-23 | trap 双引号展开 `$PY_PARSER` | `trap "rm -f $PY_PARSER" EXIT` 在 PY_PARSER 赋值前已展开为空,实际 trap 不删任何文件,临时文件永久残留。修复：`\$PY_PARSER` 转义延迟到 EXIT 时 |
| 2026-06-23 | escalate claude 进程无超时 | 失败重试时 claude -p 可能卡在网络/API 限流,父脚本永远等不到。修复：`timeout 300` 兜底,超时即放弃 |
| 2026-06-23 | SKILL.md 边界声明含已删文件 | 历史事故列表 runner.py 等已被清理,但 SKILL.md 还列着,容易误导。修复:列表改为"已删除"状态标注 |
| 2026-06-23 | 三副本 skill 同步靠 `cp` 易漂移 | ~/.claude/skills/ + ~/.agents/skills/claude-code-dispatcher + ~/.agents/skills/task-dispatcher 三份,任意一处 `cp` 遗漏即不同步。修复:三处统一 symlink 到 ~/program/claude-code-dispatcher (唯一权威源) + GitHub 版本管理 |
| 2026-06-23 | OBSERVER_LOG 无限增长 | /tmp/qx-output-{ws}.log 不轮转,长期 100MB+。修复:启动时检测 >5MB 则截断保留末 512KB |
| 2026-06-23 | verify 输出 PASS 印两遍 | `echo PASS \| tee` + 独立 `echo PASS` → 屏幕重复。修复:删独立 echo,tee 已含 stdout |

## 核心经验

1. **end-to-end 必跑一次** — 任何 skill/workflow 在写完理论后,必须跑一个真实可验证任务,理论漏洞都会暴露(exec 0 / verify 1 / escalate 起 / commit 落盘,四步全通才敢说"交付")。
2. **bash: 链式 vs bash -c 单条** — 简单判断用 `bash -c`(安全超时);带 `&&` / `||` / `2>&1 |` 链式表达必须走 `eval`(保语义)。前缀区分。
3. **escalate prompt 控制 token** — 失败现场信息价值密度 ≠ 文件大小,head/tail 截断 + 增量过滤能把单次 escalate 降到 1k token 内。
4. **symlink + GitHub = 唯一源** — 多个 skill 副本迟早漂移,一个 git 仓库 + 三个 symlink 是最少维护方案。
