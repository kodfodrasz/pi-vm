# Global Pi Instructions

## Cost-aware delegation

You may decide whether to work directly or delegate without asking first.

- Handle small tasks directly when they involve one known file, an obvious edit,
  and at most one focused validation command.
- Delegate bounded mechanical work, repository scouting, repetitive edits, and
  context gathering to the Luna-configured `scout`, `delegate`, or `worker`.
- Keep ambiguous requirements, architecture, synthesis, and final acceptance in
  the parent.
- Do not delegate when briefing and reviewing the child costs more than doing
  the task directly.
- Use one writer per working directory. Use an isolated worktree only when
  concurrent writers are genuinely useful.
- Prefer fresh context for scouts and reviewers. Use forked context only when
  session history is necessary.
- Use Terra reviewers for consequential changes. Use Sol/oracle only for
  difficult, bounded, read-only decisions.

## Default coding skill

For software development tasks, follow the `kodfodrasz` skill by default,
including in subagents. Have coding and review subagents read
`~/.pi/agent/skills/kodfodrasz/SKILL.md` unless the user asks otherwise. Scouts
do not need the skill.
