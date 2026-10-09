---
name: harness-audit
description: Audits and restructures a project's AI agent harness (CLAUDE.md, AGENTS.md, GEMINI.md, rules, skills, hooks, docs and Obsidian vault notes) so an agent starts each session with a short map and finds the rest on demand, then installs the guardrails that keep it that way. Expect the win in speed, consistency and blast radius rather than in tokens. Run manually with /harness-audit diagnose | apply | verify | check. Supports Claude Code, Codex, Cursor and Antigravity CLI, with or without Obsidian.
license: MIT
compatibility: Python 3.9+ and git. Full support for Claude Code, Codex, Cursor and Antigravity CLI (legacy Gemini CLI treated as Antigravity). Use a frontier model for diagnose/apply.
metadata:
  version: "1.5.2"
  source: "https://github.com/fabianmartinelli-fm/harness-audit"
disable-model-invocation: true
argument-hint: "diagnose | apply | verify | check"
---

# Harness audit

Goal: an agent starts each session with a small, stable map and finds everything else on demand, and the project stays that way after you leave.

Evidence to keep in mind (details in `references/principles.md`): more always-loaded instructions degrade adherence and cost; auto-generated or redundant instruction files can lower task success; so this skill **removes and relocates** more than it writes, and **measures** before and after.

`SKILL_DIR` below means the folder containing this file. Scripts need only Python and git.

## Commands

| Command | Writes | Purpose |
|---|---|---|
| `diagnose` (default) | `.harness/reports/` only | Setup interview, inventory, baseline, scorecard, change plan |
| `apply` | project files, on a git branch, after approval | Execute the approved plan, install maintenance layer |
| `verify` | `.harness/reports/` | Re-measure, lock budgets, write the final report |
| `check` | nothing | Fast maintenance lint for periodic use |

If the user gives no argument, run `diagnose`. Never run `apply` without an approved plan from `diagnose` in this project.

Write every report and question in the user's language. Keep code, file names and frontmatter keys in English.

---

## diagnose

### 1. Detect, then confirm with the user

Run `python3 SKILL_DIR/scripts/detect.py --project .` and show a short summary. It scans the repo, parent folders and common locations (Documents, iCloud Obsidian, Dropbox, OneDrive) for Obsidian vaults; if the user keeps vaults elsewhere, rerun with `--search <folder>`. Then ask, in one message, with detected answers as defaults:

1. **Agents used on this project**: Claude Code, Codex, Cursor, Antigravity CLI (Gemini CLI counts as Antigravity).
2. **Obsidian**: does this project use an Obsidian vault? List the vaults found. If yes: which vault, which folder holds this project's notes, and the topology (`inside-repo`, `repo-inside-vault`, `external`).
3. **Where agent-facing knowledge should live**: repo `docs/` (portable, versioned, works for teammates and CI) or the vault folder (single place for the human). Explain the trade-off in one sentence each; see `references/obsidian.md`.
4. **Scope of user-level files** (`~/.claude`, `~/.codex`, `~/.gemini`): include them in the measurement? They affect every project, so they are measured but never changed without explicit per-file approval.

If the user already answered some of these earlier in the conversation, do not ask again.

### 2. Safety

Run `python3 SKILL_DIR/scripts/detect.py --project . --git-only` and read `upstream`.

- Require a git repo.
- **If the working tree is unclean, survey it before asking for anything.** In both pilots what
  sat uncommitted was real work: a submodule pointer carrying a whole release of another
  repository, tag included, and a month-old stash that took a line-by-line comparison to prove
  redundant. "Commit or stash first" without evidence asks the user to decide blind. Read
  `dirty` from the same `--git-only` output and present it item by item, in the user's language:
  - **untracked build output or dependencies** (`cache`): the folder, how many files, how big,
    and the `.gitignore` line that would cover it, proposed as text. Do not edit `.gitignore`.
  - **advanced submodule pointer** (`submodules`): the commits and tags between the recorded
    pointer and the current one. That list is what says whether it is work or leftovers.
  - **modified files** (`modified`): lines changed and how long since the file was touched.
  - **other untracked files** (`untracked`): path, size, date.
  - **stashes** (`stashes`): how many, from when, how many lines in how many files each.
  Each item carries an `evidence_command` the user can run to see it for themselves. Categories
  are capped at 20 items with the remainder reported as a count, and on a slow survey the
  itemised view is dropped in favour of counts (`degraded`); `python3 .harness/scripts/dirty.py`
  gives the full list on demand.
  Then present the options by name, in this order: **commit** the work on a branch, **keep it**
  with `git stash push`, or **discard it**. Say plainly that discarding is the only irreversible
  one. About the stash, say once: it moves the work out of the way without losing it, but a
  stash is easy to forget — the second pilot had a month-old one nobody ever applied, and
  proving it was redundant cost a line-by-line comparison — so for work with any value a branch
  commit holds up better than a growing stash stack. Never present discarding as the default or
  the recommendation, and never order the options with it first.
- **This skill never cleans a working tree.** Not with a generic approval, not inside `apply`,
  not "while we are here". It never runs `git stash`, `git checkout`, `git clean`, `git reset`,
  `git add` or `git commit` over the user's uncommitted work, and the survey itself is read-only.
  The user resolves the tree outside the skill; `apply` continues once `--git-only` comes back
  clean. This is a rule, not a preference.
- **Require the branch to be current with the remote.** A baseline measured on a stale branch
  measures files that no longer exist: in the second pilot the audit read a CLAUDE.md of 11,015
  lines while the remote had 13,071, and the mismatch only surfaced mid-`apply`.
  - `behind` greater than 0 and `ahead` 0: stop. Say how many commits are missing and offer
    `git pull --ff-only`.
  - `diverged`: stop and say so. Do not propose a rebase or a merge: in a repository with
    parallel sessions and worktrees that call is the user's.
  - No `upstream` and no `origin/HEAD` (`reference` is null): record it in the report and carry
    on; a local-only project has nothing to compare against.
  - `stale_comparison` is true (`behind` is 0 but the local copy of the remote is a day or more
    old): do not stop, and say one line — the comparison is against data from
    `reference_age_days` days ago, run `git fetch` to confirm. The scripts never fetch: writing
    to the network inside someone else's repository, unasked, is not this skill's call, and a
    `behind: 0` read from stale data is exactly the false comfort the second pilot ran into.
    When `behind` is above 0 the number already says enough and this note is redundant.
- If `git_environment.wrapper_suspected` is true, note it in the report: a different `git` is
  first on PATH. The scripts call the real binary, but anything you run by hand does not.
- Nothing is written outside `.harness/reports/` during diagnose.

### 3. Baseline

Both files below are written to disk before you discuss any number. `verify` compares
against them, and a later `apply` in a new session has nothing to stand on without them.

```bash
python3 SKILL_DIR/scripts/inventory.py --project . [--include-user] --out .harness/reports/inventory-baseline.json
python3 SKILL_DIR/scripts/measure.py snapshot --project . --label baseline [--include-user]
```

Confirm `.harness/reports/inventory-baseline.json` exists before continuing. If it is missing, rerun the command; do not proceed from numbers that live only in the conversation.

**The inventory is a lower bound, never the starting total.** It counts files. It cannot
count what plugins, MCP tool schemas, custom agents and `SessionStart` hook output add,
and that difference is large: in the first pilot the inventory read 9,288 always-on
tokens while a fresh session started at about 70,000. With `--include-user` the report
lists those sources under `user_runtime` (names and commands only, never executed, never
any env value or token), so the gap is visible instead of silent. **The authoritative
starting number is `/context` in a fresh session.** Ask for it, record it, and use it in
the report; treat the static estimate as the floor.

**`/context` understates the total when Claude reads `AGENTS.md` directly.** Since v2.1.277
Claude Code reads `AGENTS.md` on its own when no `CLAUDE.md`, `.claude/CLAUDE.md` or
`CLAUDE.local.md` sits in the working directory or above it — and that file appears in neither
`/memory` nor the Memory files list of `/context`. So in a project with an `AGENTS.md` and no
`CLAUDE.md`, ask the user for one more thing: the session line
`no CLAUDE.md found; AGENTS.md loaded: <path>`. If it is there, add the size of that file (the
inventory reports it under `conditional`, kind `agents-md-direct`) to the `/context` number and
say in the report why the two disagree. If it is not there, the file is not loaded at all and
the project is running with no instructions — which is the same evidence, read the other way.

The inventory never asserts that a direct read is happening: whether the session fetched feature
flags, whether it is the first one after an upgrade, and whether the `agents-md` plugin is
enabled are invisible from disk. It reports `undetermined` with the two ways to settle it
(`/config` → Project instructions, and the `AGENTS.md loaded` line), and keeps the file out of
the always-on total until you confirm. Report both numbers and their reason; do not pick one.

Read `instruction_resolution` in the inventory before writing any number: it says which file
each agent actually reads here, the `instructionFiles` value and where it came from,
`claudeMdExcludes` from every layer, the `CLAUDE.local.md` and `AGENTS.override.md` found, and
the Claude Code version. That is the part nobody can deduce from the repository alone.

Ask the user for numbers the scripts cannot read, and pass them with `--manual '{...}'`:
- Claude Code: output of `/context` in a fresh session (total and Memory files section), plus
  the `AGENTS.md loaded` line when the project has an `AGENTS.md` and no `CLAUDE.md`.
- Cursor: context usage shown in a fresh chat.
- Antigravity: `agy inspect` output for loaded context files, rules and skills.

**Say which chars-per-token ratio produced every estimate, and never call an estimate a
measurement.** The default 4.00 is the figure for running English prose; a harness is not
prose, and the third pilot measured 2.10 over 600,892 characters of dense technical
markdown — an error of 1.90x, always downwards, so a project twice over budget reads as
inside it. The cause is the shape of the text (tables, bold markers, backticked
identifiers, paths, UUIDs), not its language: a technical repository in English is
underestimated just as badly. Once you have a real `/context`, calibrate and record it:

```bash
python3 SKILL_DIR/scripts/measure.py calibrate --manual '{"context_memory_files_tokens": 285800}' --apply
```

Calibrating raises every estimate at once, which is the point — the old ones were a floor —
so H002 and the ratchet will fire on projects that looked inside their budget. Re-baseline
the ratchet afterwards with `lint.py --update-lock`.

**When the always-on estimate exceeds the context window of the smallest model in use, that
is a hard failure, not a budget overrun, and the report says so in those words.** In the
third pilot the `CLAUDE.md` alone was worth ~279,000 tokens: no 200k model could open the
project at all — not for a trivial question, with no tools loaded. Set
`budgets.context_window` in `.harness/config.json` to that model's window and H002 changes
its message accordingly; without it, the check is yours to make and to write down.

Optional but recommended: agree on 3 to 5 representative tasks for this project (see
`references/rubric.md`, "Task benchmark"). **The tasks are run by the user, in a fresh
session, on both sides of the comparison.** Not by you and not by a subagent: a subagent
inherits the context snapshot its parent session started with, so it measures the harness
as it was at startup, whatever is on disk now. The "before" side gets away with it only
by coincidence — at that point the startup snapshot and the disk still agree.

### 4. Read the harness

Read every always-on file listed in the inventory and a sample of the largest docs. For the agents in use, read the matching `references/agents/<agent>.md`. If Obsidian is in use, read `references/obsidian.md`.

### 5. Score and plan

Score the harness with `references/rubric.md`. Then **write `.harness/reports/plan.md` to disk
before presenting anything to the user**, using the structure in `references/report-template.md`
(section "Plan"). The file is the plan; what you say in the conversation is a summary of the
file. A plan that exists only in the conversation is lost the moment the session ends, and
`apply` in a new session will refuse to run.

Also record in the plan any missing sensor: if the project has no lint command, `install.py`
installs no code sensor, and that is a gap to state explicitly, not something to paper over by
installing a check that cannot run.

Each proposed change must state: what moves, from where, to where (per `assets/templates/PLACEMENT.md`), estimated always-on tokens saved per agent, and risk level:

- **low**: frontmatter, index, links, moving files into placement folders, deleting exact duplicates generated by tools.
- **medium**: moving content out of entry files into rules, skills or docs; scoping rules; converting prose rules into hooks or lint.
- **high**: merging or rewriting knowledge, archiving notes, anything outside the repo (user-level files, the vault when external).

Rules for the plan:
- Prefer relocation over rewriting. Keep the user's wording when moving content.
- Entry file target: a map, not an encyclopedia. One canonical `AGENTS.md` for all agents; `CLAUDE.md` starts with `@AGENTS.md` plus only Claude-specific lines; `GEMINI.md` should not repeat `AGENTS.md`.
- **Keep the `@AGENTS.md` import even though Claude Code can now read `AGENTS.md` by itself.**
  The import is the only arrangement that holds in every session, provider and configuration:
  a version before v2.1.277, the first session after an install or upgrade, Amazon Bedrock or
  any session without feature flags, telemetry disabled, `disableAllHooks`,
  `allowManagedHooksOnly`, the `agents-md` plugin switched off, or a teammate whose Project
  instructions is `claude-md`. It also survives a personal `CLAUDE.local.md`, which otherwise
  switches the direct read off for that one person. The import never causes a double read under
  any value of Project instructions — Claude Code skips an `AGENTS.md` it already loaded. Treat
  the direct read as a convenience that saves a file, not as an equivalent arrangement, and
  never plan to delete a `CLAUDE.md` whose only content is `@AGENTS.md`.
- Remove what agents can discover by themselves (directory listings, dependency lists, generic advice). Keep non-obvious commands, gotchas, and conventions that differ from defaults.
- Anything that must always happen becomes a hook, linter or CI step, not a sentence.
- **A rule that becomes a command guard carries three requirements**, and they are not
  optional refinements — the third pilot lost work to all three in one afternoon. This skill
  installs no command guard itself; these are requirements the plan writes into the project.
  1. The matcher matches the **command**, not the string anywhere in the text: strip
     heredocs and quoted content before matching. Without that, the guard refuses the commit
     whose message explains the rule, and every command written to fix the guard is blocked
     too, because each one quotes the string.
  2. A test case, in the project's own suite, asserting that
     `git commit -m "never use <forbidden command>"` **passes**. A sensor that gets in the
     way of writing about itself is a sensor someone switches off on a Friday night.
  3. After any block, check what of the call actually happened. A blocked call is aborted
     whole, so it takes unrelated work down with it, silently: in the pilot a refused Bash
     call also carried the creation of a script, and it was reported as existing for three
     turns before anyone noticed it never did.
- Never plan to delete knowledge. Superseded content gets `status: superseded`.

Present the scorecard and a summary of the plan grouped by risk, and say where the file is.
Ask the user to approve: low as a batch, medium per group, high item by item. Write the
approvals back into `plan.md` as they come in, so the decisions survive the session too.

---

## apply

0. Rerun the safety check: `python3 SKILL_DIR/scripts/detect.py --project . --git-only`. `apply`
   often runs in a later session, and the branch can have fallen behind since `diagnose`. Same
   rules as diagnose step 2, plus: if the branch moved at all since the baseline, say so and ask
   whether to re-measure before changing anything.
0b. Require the approved plan on disk. Read `.harness/reports/plan.md`; a baseline at
   `.harness/reports/inventory-baseline.json` should be there too. If `plan.md` is missing,
   refuse and say exactly this: the file `.harness/reports/plan.md` does not exist, so there is
   no approved plan in this project; recreate it by running `/harness-audit diagnose`, which
   writes the plan and the baseline before asking for approval. Never reconstruct the plan from
   memory or from the conversation.
1. `git switch -c harness-audit/<date>`.
2. Install the maintenance layer (dry run first, show the output, then apply):
   ```bash
   python3 SKILL_DIR/scripts/install.py --project . --agents <list> --docs-dir <dir> \
     [--vault-path <vault> --vault-topology <t>] --entry-blocks --with-precommit [--with-ci]
   python3 SKILL_DIR/scripts/install.py ... --apply
   ```
   The pre-commit goes into `.githooks/` (tracked by git) and `core.hooksPath` is pointed at it,
   so a clone gets the sensor and CI is not the only gate. Two cases where the installer steps
   back and tells you instead: `core.hooksPath` already points somewhere else (husky), where it
   installs there and changes nothing; and untracked executable hooks already in `.git/hooks`,
   where it installs nothing, because setting `core.hooksPath` would silently disable them.
   Relay that message to the user and let them decide. With a `package.json` present, a
   `prepare` script arms the hooks on `npm install`, and the entry file documents the manual
   command for everyone else.
   The opening budgets are set from what the project measures today, not from the default
   targets, and are marked `budgets_transitional` in `.harness/config.json`. A gate that is red
   on its first run blocks the very commits that are shrinking the harness, which is what
   happened in the second pilot. The photograph is the starting line; the ratchet does the
   lowering, exactly as the code sensor does. `lint.py` warns (`H019`) on every run while the
   mark is there, so a transitional budget cannot quietly become permanent.
3. Execute only approved plan items. Move scoped rules into `.harness/rules/` and procedures into `.harness/skills/`. Add frontmatter to docs. Slim entry files.
4. Regenerate and check:
   ```bash
   python3 .harness/scripts/sync.py
   python3 .harness/scripts/build_index.py
   python3 .harness/scripts/lint.py
   ```
   Fix errors. Warnings may remain only if listed in the report with a reason.
5. Append to the docs log: `## [YYYY-MM-DD] audit | harness restructured (see .harness/reports/)`.
6. Commit in small, reviewable commits (install, relocation, entry files). Do not merge: the user reviews the branch.

For agent-specific install steps (Codex hook trust, Antigravity hook schema, Cursor restart), follow `references/agents/<agent>.md`.

---

## verify

1. Ask the user to open a fresh session in each agent and share the same manual numbers as the
   baseline. The comparison that matters is `/context` before against `/context` after: the
   script totals are a lower bound and miss plugins, MCP servers, agents and hook output.
   If the project has an `AGENTS.md` and no `CLAUDE.md`, ask again for the
   `no CLAUDE.md found; AGENTS.md loaded: <path>` line and add that file to both sides of the
   comparison — `/context` leaves it out, so comparing the raw numbers would credit the audit
   with a reduction it did not make, or hide one it did.
2. `python3 .harness/scripts/measure.py snapshot --label after --manual '{...}'`
3. `python3 .harness/scripts/measure.py compare --before baseline --after after`
4. **Measure what you can measure alone, and hand the rest back.** `verify` produces on its
   own: the `/context` comparison (from the number the user pastes, as in step 1), lint,
   budgets and ratchet, entry-file sizes, and Codex read coverage (`AGENTS.md` bytes against
   `project_doc_max_bytes`). It cannot produce the behavioural half. Say so in one sentence
   rather than leaving it out: **you cannot open a fresh session, and a subagent inherits the
   context snapshot this session started with, so it would measure the harness as it was
   before the change, not as it is now.** Promising it anyway is what cost the third pilot
   2.17M tokens and five confident, false verdicts.
   So, if task benchmarks were agreed: prove the environment, then present the prompts.
   ```bash
   python3 .harness/scripts/benchenv.py --dir <worktree> --commit <audit commit> --main .
   ```
   Run it for every directory a task will run in, **before** the battery and **again after**
   — an environment can change in the middle, and a task believed to be read-only wrote a
   migration file into the main tree in the pilot. Exit 1 means abort: do not launch to see
   what happens. Paste its output into the report beside the verdicts.
   Then give the user the prompts, ask them to run each one in a fresh session of the agent
   and model being measured, and ask for, per task: success, turns, startup and peak context,
   **tokens and tool uses**, irrelevant files read, human corrections.
5. Feed the task numbers back in and let the comparison judge them:
   `measure.py snapshot --label after --manual '{"tasks": [{"id": "T1", "tokens_before": …, "tokens_after": …}]}'`.
   `compare` exits 2 when a large always-on reduction comes back with a flat per-task cost:
   those two numbers cannot both be right, and the usual cause is an environment that is not
   the one the audit changed. Do not report verdicts from a run that exits 2.
6. If always-on context went up for any agent, or benchmarks got worse, say so plainly and propose a rollback of the responsible change.
7. Lock the new budgets so they can only shrink:
   `python3 .harness/scripts/lint.py --update-lock --close-transitional`.
   `--update-lock` on its own records the ratchet baseline and leaves the transitional
   budgets alone, because closing them freezes whatever the project measures at that moment
   as its permanent budget: run halfway through a migration it locks in the half-migrated
   state and removes the H019 that says the budget is provisional. `--close-transitional`
   belongs here, once, when the plan is done. It prints the before and after per budget and
   per agent — show that output to the user.
8. Write `.harness/reports/HARNESS-REPORT.md` with `references/report-template.md` (section
   "Final report"). Every number in it records **which process produced it**: a fresh session
   run by the user, a local script, or a subagent.

---

## check

`python3 .harness/scripts/lint.py` (or `SKILL_DIR/scripts/lint.py` if not installed yet), plus
`python3 .harness/scripts/code_sensor.py` when a code sensor is installed. Summarize findings by severity, propose fixes, and suggest a full `diagnose` when budgets are breached (`H002`, `H006`, `H015`) or more than 10 warnings accumulated.

`H020`, `H021` and `H022` are about which instruction file each agent ends up reading, and all
three are silent in daily use: a personal `CLAUDE.local.md` that switches the team's `AGENTS.md`
off for one person, a `CLAUDE.md` over 4 MiB that Claude Code skips whole instead of truncating,
and an `AGENTS.override.md` that Codex reads with precedence and Claude Code never reads. Report
them with the resolution line from the inventory, not on their own.

## Reference files

- `references/principles.md`: why this design (context rot, instruction budget, progressive disclosure, guides and sensors). Read once per audit.
- `references/rubric.md`: scorecard criteria, thresholds, task benchmark method.
- `references/obsidian.md`: vault topologies and how agents reach notes.
- `references/agents/claude-code.md`, `codex.md`, `cursor.md`, `antigravity.md`: what each agent loads and how its hooks work.
- `references/report-template.md`: plan and final report structure.
- `assets/templates/PLACEMENT.md`: the placement map installed into the project.
- `scripts/dirty.py`: read-only survey of an unclean working tree (cache, submodule pointers, modified files, untracked files, stashes) with the evidence for each.
- `scripts/code_sensor.py`: per-file ratchet over the project's own linter (fails only when a file gets worse). Configured under `code_sensor` in `.harness/config.json`.
- `scripts/benchenv.py`: proves a benchmark directory is on the commit you think it is, with
  observable artefacts, and that the main tree is clean. Exit 1 aborts.
