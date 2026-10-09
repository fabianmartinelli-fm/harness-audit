# Changelog

## [1.5.2] - 2026-10-09

**The user memory file no longer leaks into the project count.** The inventory walks from the
project up to `HOME` looking for `CLAUDE.md`, `.claude/CLAUDE.md` and `CLAUDE.local.md`. For any
project under `HOME`, the last stop of that walk is `HOME` itself, where `.claude/CLAUDE.md` is
not a project file: it is `~/.claude/CLAUDE.md`, the user memory. It was counted as always-on
project context even without `--include-user`, so a run meant to measure only the project
reported the user's personal instructions as the project's cost.

- **`~/.claude/CLAUDE.md` counts only with `--include-user`**, and still exactly once when the
  flag is set. Two smoke checks cover both cases.

## [1.5.1] - 2026-09-23

**The repository moved account.** The GitHub profile username changed, so every clone URL,
release link, CI badge and skill `source:` field named an account that no longer owns the
repository. GitHub redirects the old path for now, but the redirect is not a guarantee: it
breaks the moment anyone claims the abandoned name, and a `source:` field is read by an agent
deciding where its own instructions came from, not by a browser that follows a 301. Anything
already installed from 1.5.0 or earlier carries the old address in its frontmatter — reinstall
from this release, or edit the `source:` line in place. No behaviour changed.

- **Install instructions and metadata now point at `fabianmartinelli-fm/harness-audit`**:
  `README.md`, `README.pt-BR.md`, both `SKILL.md` files and the keeper template.

## [1.5.0] - 2026-09-21

**Corrections from the third pilot.** Fourteen findings on a project whose `CLAUDE.md` was
6,198 lines and 589 KB, with an `AGENTS.md` that Codex was reading at 19%. The audit worked —
startup context 347.2k to 70.5k, memory files 285.8k to 9.3k, Codex back to 100% — but the
behavioural half of the "after" benchmark was invalid, and the sharpest findings are about
this skill claiming or ordering things that do not hold. A number taken in the wrong place is
worse than no number: it produces a confident, false conclusion. Most of what follows exists
to stop that.

**If you already installed 1.4.0 or earlier:** `lint.py --update-lock` no longer closes the
transitional budgets on its own. If you ran it in the middle of a migration, your gate is
frozen at whatever the project measured at that moment and the `H019` that would say so is
gone — check `.harness/config.json`, and redo the closing step after `verify` with
`lint.py --update-lock --close-transitional`.

### The symptom, and what changed

- **Five task verdicts were confident and false, and cost 2.17M tokens.** `verify` step 4
  told the agent, in the imperative, to rerun the benchmark in fresh sessions; step 1 already
  delegated that to the person. The agent cannot do it — it does not open sessions, and a
  subagent inherits the context snapshot its parent session started with, so it measures the
  harness as it was at startup regardless of what is on disk. `verify` now measures alone what
  it can measure alone (`/context` from the number the user pastes, lint, budgets, ratchet,
  entry-file sizes, Codex read coverage), presents the benchmark prompts, asks the person to
  run them in a fresh session, and **says in one sentence why it cannot do it itself**. The
  same correction applies to the "before" side in `diagnose`, which was right only by
  coincidence: at that point the startup snapshot and the disk still agreed. Every number in
  the final report now records which process produced it.
- **The whole "after" battery ran against the old harness, in worktrees born from the default
  branch.** Five tasks, no valid measurement — and results were written from it, crediting
  scoped rules that did not exist in that tree. New **`scripts/benchenv.py`** resolves a
  directory's HEAD, asserts the audit commit is an ancestor of it, proves the state by
  observable artefact (entry-file line counts, docs directory, scoped rules on disk) and
  checks the main tree for stray writes. Exit 1 aborts. Run it before the battery and again
  after, and paste its output into the report next to the verdicts.
- **Two tasks came back at −2.4% and +1.6% against an always-on 96.5% smaller, and that was
  printed under a table and read as success, twice.** It was the signal that the environment
  was wrong. `measure.py compare` now takes tokens and tool uses per task in the `after`
  snapshot's `--manual`, prints the delta beside the verdict, and **exits 2** when a declared
  reduction above 50% comes back with a median per-task cost change below 10% — those two
  numbers cannot both be right. Thresholds under `benchmark` in `.harness/config.json`. With
  no task numbers at all, the comparison says the behavioural half was not measured instead of
  passing in silence. A signal that depends on somebody remembering to look at it is not ready.
- **`CLAUDE.md` was estimated at 146,498 tokens and measured at 278,713.** 4.00 chars per
  token is the figure for running English prose; the pilot measured **2.10** over 600,892
  characters of dense technical markdown — 1.90x, always downwards, so a harness twice over
  budget reads as inside it. The cause is the shape of the text (tables, bold markers,
  backticked identifiers, paths, UUIDs, hashes), **not its language**: a technical repository
  in English is underestimated just as badly. New **`measure.py calibrate`** derives the ratio
  from one real `/context` and writes `budgets.chars_per_token`; every report states which
  ratio produced its numbers. A ratio derived this way predicted a file set 69.7% smaller to
  within 0.1%, which is why calibration beats a heuristic over backtick density — a heuristic
  would move every number in the project, including the ratchet lock, with nobody able to say
  whether it is right. Calibrating raises every estimate at once, so it prints the warning to
  re-baseline the ratchet.
- **No 200k-window model could open the project at all.** Before the restructure the
  `CLAUDE.md` alone was worth ~279,000 tokens, which exceeds the window before any system
  prompt, tool definition or question. That is not "over budget", it is "does not start", and
  `H002` compared against a fixed budget of 5,000 with no way to say it. Set
  `budgets.context_window` to the window of the smallest model in use and `H002` changes its
  message accordingly.
- **41 identical paragraphs were reported as "paid twice" when nobody paid twice.** Claude
  Code reads only `CLAUDE.md`, Codex only `AGENTS.md`; the two files were a fork two months and
  4,444 lines apart, with Codex on July's truth, truncated, with no signal. New **`H023`**
  fires when shared paragraphs come with a line-count divergence above 20% and says who is
  reading the stale side; `H011` stays for the real double payment. Dates are deliberately not
  read: mtime lies after a clone and an in-file "updated on" stamp is not parseable in general.
- **The gate did not block the migration — it went quiet after it.** Reproduced on a fixture:
  install opens the budgets at 1,803 entry-file lines and 48,662 tokens, marked transitional,
  and the lint is silent, exactly as designed in 1.4. But `lint.py --update-lock` run
  mid-migration closed those budgets as a side effect, freezing the half-migrated state
  (1,713 lines, 23,743 tokens) as permanent and removing `H019`. The restructure then finished
  under 10 lines and the gate stayed two orders of magnitude too loose, with nothing left to
  say it was ever temporary — which is harder to notice than a red gate, because it looks
  exactly like passing. Recording the ratchet baseline and closing the budgets are now separate
  decisions: the second needs `--update-lock --close-transitional`, and belongs in `verify`.
- **The ratchet was switching itself off in silence.** With no lock file, `locked` is `None`
  and the comparison short-circuits: nothing is read, nothing is compared, and the run passes.
  That is the state of every branch older than the audit — the most likely regressive merge is
  exactly the case the ratchet did not look at. New **`H024`** reports it. (The larger question
  it comes from — a ratchet whose reference lives inside the tree it audits travels with the
  merge that should have been blocked — is not answered here.)
- **The lint proposed a "fix" that would have corrupted the documentation of a live
  protocol.** `[[PRODUCT:<uuid>|name]]` is a product-link marker an edge function emits, not a
  note reference, and `H017` told the author to replace it with a relative markdown link. A
  colon or an angle-bracket placeholder in the target is now treated as the signature of
  machine syntax, and `lint.suppress` in `.harness/config.json` takes per-code glob lists for
  everything else. Severity stays `info` — as `error` it would have blocked a commit for
  documenting the truth.
- **A vault folder with an overview, 204 lines of decisions and 361 of log was reported as not
  existing.** `detect.py` required an exact name match, so `B01 Projetos/tavoloo/` was invisible
  to a project directory called `tavoloo-fmsolutions-main`, and the diagnose nearly concluded
  there was no knowledge layer at all. Matching is now on tokens of 4 characters or more, and
  every vault reports its top-level folders: an empty match list is not an answer, it is the
  absence of one.
- **2 of 5 benchmark tasks were no-ops, and a task believed to be read-only wrote a migration
  file into the main tree.** The rubric now says who runs the tasks, where they run and where
  they come from: every task in an isolated worktree or copy with no exceptions ("this task
  only reads" is a hypothesis about the agent, and the benchmark exists because that hypothesis
  is not reliable); at least one task from outside the entry file's incident blocks, because a
  block exists *because somebody already fixed that trap* and a task derived from it points at
  code already in its final state; and a check that the target state does not exist yet, before
  running anything.
- **A command guard refused the commit whose message explained the rule, and the blocked call
  took unrelated work down with it.** Every command written to fix the guard quoted the
  forbidden string and was blocked too; a script the same call would have created was reported
  as existing for three turns and never did. This skill installs no command guard — `SKILL.md`
  now states the three requirements the plan writes into the project: match the command and not
  the string anywhere in the text (strip heredocs and quoted content first), keep a test
  asserting that `git commit -m "never use <forbidden command>"` passes, and after any block
  check what of the call actually happened.

## [1.4.0] - 2026-09-19

**How each agent resolves which instruction file it reads.** Claude Code now reads `AGENTS.md`
on its own (v2.1.277+), and the rules around that create failures nothing warns about: the file
is loaded but invisible to `/context`, or silently switched off for one person.

- **`/context` is no longer the whole answer.** An `AGENTS.md` that Claude reads directly
  appears in neither `/memory` nor the Memory files list of `/context`, so the number the user
  reports is short by the size of that file. `diagnose` and `verify` now ask for the session
  line `no CLAUDE.md found; AGENTS.md loaded: <path>` whenever the project has an `AGENTS.md`
  and no `CLAUDE.md`, add the file to the count, and say why the two numbers disagree.
- **The inventory reports the effective resolution, not just the files.** New
  `instruction_resolution` block, also printed as one line per agent on stderr: which file each
  agent actually reads here, the `instructionFiles` value and which settings file it came from,
  `claudeMdExcludes` from every layer, the `CLAUDE.local.md` and `AGENTS.override.md` found, and
  the Claude Code version. `instructionFiles` is read from user and managed settings only,
  because Claude Code ignores it in project and local settings.
- **A direct read is never asserted.** Whether a session reads `AGENTS.md` also depends on the
  provider and its feature flags, on it not being the first session after an upgrade, and on the
  `agents-md` plugin being enabled — none of it readable from disk. The answer is `undetermined`
  with the two ways to settle it, and the file is reported as `conditional` with its size,
  outside `always_on_est_tokens`. A total that moves with an assumption is worse than two
  numbers with their reason. A negative answer is still stated plainly: nothing on that list
  ever makes Claude read a file it would otherwise skip.
- **New lint codes.** `H020` (warn): a `CLAUDE.local.md` — personal, gitignored — switches the
  team's `AGENTS.md` off for one person while the repository still looks right; the message
  gives both ways out. `H021` (error): a `CLAUDE.md` over 4 MiB is skipped whole, not truncated.
  `H022` (warn): `AGENTS.override.md` is read by Codex with precedence and never by Claude Code.
- `references/agents/claude-code.md` carries the resolution table, what counts and what does not
  for the `AGENTS.md` shutdown, the five kinds of session that never read it, and where the
  direct read differs: no `/memory` or `/context` entry, `InstructionsLoaded` hooks do not fire
  (no sensor this skill installs depends on that event), and an external `@path` import inside it
  loads with no dialog when the project approved external imports before.
- **Bug fix: `~/.claude/CLAUDE.md` was counted twice.** An inventory run with `--include-user`
  picked the user memory file up twice in two situations: when the audited project sits **below
  your home directory**, because the walk up the parent directories reaches `~` and the
  `--include-user` step then adds the same file again; and whenever a project `CLAUDE.md`
  **imports `@~/.claude/CLAUDE.md`** by hand, wherever the project lives, because the import
  expansion and the user-file step did not share a seen-set. Both added the file's tokens to the
  always-on total twice. Every `--include-user` baseline, snapshot and `HARNESS-REPORT.md`
  produced in either situation **overstates** always-on context by the size of that file, and so
  does any `budgets.lock.json` locked from one. Re-run `inventory.py --include-user` for the
  real number; `lint.py --update-lock` re-locks it. Runs without `--include-user` were never
  affected, and neither were the two pilots published in the README: both ran from
  `/Volumes/...` with no `@~/` import, and their reports show the file counted once
  (9,288 → 7,815 and 392,448 → 11,087 stand as measured).
- `SKILL.md` now says why `CLAUDE.md` with `@AGENTS.md` on top stays the canonical arrangement:
  it is the only one that holds in every session, provider and configuration, and the import
  never causes a double read under any value of Project instructions. The direct read is a
  convenience, not an equivalent.

## [1.3.0] - 2026-09-18

**New rule: the skill never cleans a working tree** — not with a generic approval, not inside
`apply`. It surveys, presents the evidence and the named options, and the user decides.

- An unclean working tree is now surveyed before anyone is asked to clean it. In both pilots
  what sat uncommitted was real work — a submodule pointer carrying a whole release of another
  repository, tag included, and a month-old stash that took a line-by-line comparison to prove
  redundant — and both times it was the agent's own initiative that found out. `diagnose` now
  presents, per item: untracked build output grouped by root directory with the `.gitignore`
  line it would need, an advanced submodule pointer with the commits and tags between the
  recorded pointer and the current one, modified files with lines changed and age, other
  untracked files with size and date, and stashes with date, files and lines. Each item carries
  the read-only command that shows the evidence. Then the options are named in order — commit,
  stash, discard — with discard last and marked as the only irreversible one.
  New `scripts/dirty.py`, folded into `detect.py --git-only` so `apply` sees the same survey.
- Written as a rule in `SKILL.md`: the skill never cleans a working tree. Not with a generic
  approval, not inside `apply`. The survey is read-only and runs no `stash`, `checkout`,
  `clean`, `reset`, `add` or `commit`, and it does not edit `.gitignore`.
- The survey carries no file content, and the text the user wrote (a stash message, a submodule
  commit subject, a filename) is clipped to 80 characters and passed through the secret mask
  before it reaches `.harness/reports/`. Categories are capped at 20 items with the remainder
  counted, and a survey slower than 2 seconds reports counts only.

## [1.2.0] - 2026-09-18

Three fixes from the second pilot: a large product repository with a submodule, 25 worktrees,
several sessions shipping pull requests in parallel and two agents.

### Change for projects installed with 1.1.0

The opening budgets now come from the measured project instead of the fixed defaults, so a
project carrying legacy no longer starts with a red gate; an existing `.harness/config.json` is
untouched until you rerun `install.py`.

### Fixes

- The safety check now looks at the remote. `diagnose` stops when the branch is behind its
  upstream, saying how many commits are missing and which command brings them, and stops on a
  divergence without proposing a rebase, because in a repository with parallel sessions that
  call belongs to the user. With no `@{upstream}` it falls back to `origin/HEAD`, and only
  records the absence when there is neither. `apply` reruns the same check, since it often runs
  in a later session: `detect.py --git-only` prints just the git state for that.
  In the pilot the baseline was measured on a branch 48 commits behind, against a `CLAUDE.md` of
  11,015 lines while the remote had 13,071, and it only surfaced mid-`apply`.
  No script fetches: writing to the network inside someone else's repository, unasked, is not
  this skill's call. Instead the answer carries its own age (`reference_age_days`), and a
  `behind: 0` measured against a reference a day or more old is flagged (`stale_comparison`)
  with a one-line note to run `git fetch`, because that false comfort is what the pilot hit.
- `install.py` sets the opening budgets from what the project measures after installation,
  never looser than the targets, and marks them `budgets_transitional`. A gate installed at the
  default budget over a legacy harness is red on its first run and blocks the very commits that
  are shrinking it. `lint.py` warns (`H019`) on every run while the mark is there, so a
  transitional budget cannot quietly become permanent, and `lint.py --update-lock` tightens the
  budgets to the real values, printing the before and after per budget and per agent.
- All git reads whose format the scripts parse now call the real binary (`/usr/bin/git`, or the
  first `git` on PATH when that is missing). A wrapper on PATH broke the worktree parser in the
  pilot by returning the human format for `git worktree list --porcelain`. Reports carry
  `git_environment`, which flags a different `git` sitting first on PATH.

## [1.1.0] - 2026-09-17

Three fixes from the first real pilot (a Next.js site audited with Claude Code and Codex).

### Breaking change for projects installed with 1.0.0

The pre-commit is now installed into `.githooks/` and armed with `core.hooksPath`, instead of
`.git/hooks/`, which git does not version: in the pilot the sensor existed only on the machine
that ran `apply`, a clone got nothing, and there was no CI. A project set up with 1.0.0 keeps
working, but its hook stays unversioned. To migrate, rerun `install.py --with-precommit --apply`
from the 1.1.0 skill after moving any hook of your own out of `.git/hooks/` (the installer
refuses to touch an active `.git/hooks` and an existing `core.hooksPath`, husky included, and
tells you instead).

### Also in this release

- Skill description now states what the pilot measured: task success unchanged, context per task
  down 8%, time down about fivefold, side effects from 6 to 0.

- `diagnose` now writes `.harness/reports/plan.md` and `inventory-baseline.json` to disk **before**
  presenting anything; the conversation is a summary of the file. `apply` refuses without the plan
  and names the missing file and the command that recreates it. In the pilot the plan existed only
  in the conversation and had to be rebuilt by hand in the next session.
- `install.py` installs the pre-commit into `.githooks/` (tracked by git) and points `core.hooksPath`
  at it, adds an npm `prepare` script and documents the manual command in the entry file, so a clone
  gets the sensor. It steps back and warns instead of taking over when `.git/hooks` already holds
  active hooks, and installs into an existing `core.hooksPath` (husky) rather than replacing it.
  The CI workflow runs `sync --check`, the harness lint and the code sensor.
- New `scripts/code_sensor.py`: a per-file ratchet over the project's own linter, ESLint by default
  when a `package.json` is present, any tool that lists problems per file otherwise. It fails only
  when a file goes above its own baseline, because a binary gate is unusable on a codebase with
  pre-existing problems. No lint command means no sensor, and `diagnose` records that as a gap.
- `inventory.py --include-user` now lists enabled plugins, custom and plugin agents, MCP server
  names and `SessionStart` hook commands, and labels its own total a lower bound: the pilot's
  inventory read 9,288 always-on tokens against a real session start of about 70,000. Hooks are
  never executed, MCP entries carry names only, and env values, headers, URLs and any
  `token=`/`key=`/`secret=`/`password=` pair are masked out of the report.

## [1.0.0] - 2026-09-17

First public release.

- `harness-audit` skill with `diagnose`, `apply`, `verify` and `check`.
- `harness-keeper` skill installed into projects for every agent.
- Adapters for Claude Code, Codex, Cursor and Antigravity CLI (legacy Gemini CLI handled by Antigravity).
- Obsidian support: vault detection, three layouts, generated index from frontmatter.
- Deterministic scripts: inventory, lint (H001 to H018), sync, index, hooks, measurement, transcripts.
- Maintenance layer: placement map, post-edit and stop hooks, git pre-commit, optional GitHub Actions.
- Ratchet on always-on budgets.
- Upload-ready packages validated for a single `SKILL.md` with standard frontmatter.
