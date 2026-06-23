# claude-code-dispatcher

Plan-and-dispatch workflow: user discusses requirements in the dialog, writes structured instructions, dispatches to Claude Code in a persistent tmux session for execution + verification, captures results via marker files, and reports back. Survives restarts.

## Layout

- `SKILL.md` — Claude Code skill description (loaded from `~/.claude/skills/`)
- `qx-workflow.sh` — Execution engine (worktree isolation + exec/verify + escalation)

## Install

```bash
mkdir -p ~/.claude/skills
ln -sfn ~/program/claude-code-dispatcher ~/.claude/skills/claude-code-dispatcher
```
