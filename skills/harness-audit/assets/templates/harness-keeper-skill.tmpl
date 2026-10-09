---
name: harness-keeper
description: Keeps the project harness organized on every change. Use whenever you are about to create, move, rename or update documentation, notes, decisions, plans, rules, skills, AGENTS.md, CLAUDE.md or GEMINI.md, when you finish a feature or plan, or when a harness hook or lint reports a problem. Use it even if the user did not mention documentation.
license: MIT
compatibility: Requires Python 3.9+ and a project set up by harness-audit (.harness/ folder). Works with Claude Code, Codex, Cursor and Antigravity CLI.
metadata:
  version: "1.5.2"
  source: "https://github.com/fabianmartinelli-fm/harness-audit"
---

# Harness keeper

The project was organized so agents load little by default and find the rest on demand.
Your job is to keep it that way. Every piece of information has exactly one home.

## Before writing anything

1. Read `.harness/PLACEMENT.md`. It says where each kind of information goes.
2. Open the docs index (path in `.harness/config.json`, usually `docs/index.md`) and check whether a doc on this subject already exists. Prefer updating it over creating a new one.
3. If nothing in the placement map fits, ask the user instead of inventing a new folder.

## While writing

- Docs need frontmatter: `description` (one line), `read_when`, `status`, `updated` (YYYY-MM-DD).
- Always-on files (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, unscoped rules) stay small and stable. No dates, status or current-work notes there: that content goes in `docs/plans/` or `docs/log.md`. Stable content also keeps the prompt prefix cacheable.
- Scoped rules and skills are edited only in `.harness/rules/` and `.harness/skills/`. Files in `.claude/`, `.cursor/rules/` and `.agents/skills/` marked as generated are copies.
- Pointers use plain relative paths, never `@imports` of docs (they load every session) and never bare `[[wikilinks]]` (agents cannot resolve them).
- Never delete knowledge. Set `status: superseded` and link to what replaces it.
- A plan that is done moves from `plans/active/` to `plans/completed/` with `status: completed`.

## Before you finish

Run, in order, and fix anything reported:

```bash
python3 .harness/scripts/sync.py
python3 .harness/scripts/build_index.py
python3 .harness/scripts/lint.py
```

Then append one line to the log: `## [YYYY-MM-DD] <kind> | <what changed>`.

If a hook blocked you, its message lists the exact problems and fixes. Apply them rather than working around the hook.
If a budget check fails (`H002`, `H015`), do not raise the budget yourself: move content out of the always-on layer or tell the user what would need to grow and why.
