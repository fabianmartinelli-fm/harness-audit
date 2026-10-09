#!/usr/bin/env bash
# End-to-end smoke test on a throwaway fixture. Usage: bash tests/smoke.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/skills/harness-audit/scripts"
T="$(mktemp -d)"; P="$T/proj"; mkdir -p "$P" && cd "$P"
git init -q && git config user.email t@t && git config user.name t
fail=0; check() { if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got $1, want $2)"; fail=1; fi; }

python3 - <<'PY'
import json, os
os.makedirs("docs/notes", exist_ok=True); os.makedirs(".claude/rules", exist_ok=True); os.makedirs(".cursor/rules", exist_ok=True)
para = "Shared paragraph long enough to be detected as duplicated content across the entry files of this fixture project."
open("CLAUDE.md","w").write(f"# P\n\n{para}\n\nCurrently migrating billing (2026-09-10).\n@docs/big.md\n" + "\n".join(f"- rule {i}" for i in range(150)))
open("AGENTS.md","w").write(f"# P\n\n{para}\n")
open("docs/big.md","w").write("x " * 30000)
open(".claude/rules/api.md","w").write("- validate\n")
open("package.json","w").write(json.dumps({"name": "fixture", "devDependencies": {"eslint": "^9"}}, indent=2) + "\n")
open("lintstub.py","w").write(
    "import pathlib\n"
    "print(pathlib.Path('lintstub.txt').read_text() if pathlib.Path('lintstub.txt').exists() else '')\n")
open("lintstub.txt","w").write("src/a.js:3:1: error x\nsrc/a.js:9:2: error y\nsrc/b.js:1:1: error z\n")
PY
git add -A && git commit -qm init

python3 "$S/lint.py" >/dev/null; check $? 1 "lint flags messy fixture"
python3 "$S/measure.py" snapshot --label baseline >/dev/null; check $? 0 "baseline snapshot"
python3 "$S/install.py" --agents claude-code,codex,cursor,antigravity --entry-blocks --with-precommit --with-ci --apply >/dev/null; check $? 0 "install apply"

# --- 1.2 correction 2: the gate opens on what exists, not on a fixed target
python3 -c "
import json;c=json.load(open('.harness/config.json'))
assert c['budgets']['entry_file_lines'] > 120, c['budgets']
assert c['budgets_transitional']['targets']['entry_file_lines'] == 120, c['budgets_transitional']"; check $? 0 "opening budgets measured from the project, not the default"
lint_out=$(python3 .harness/scripts/lint.py 2>/dev/null)
[[ "$lint_out" != *H001* && "$lint_out" != *H002* ]]; check $? 0 "fresh gate is not red over the legacy harness"
[[ "$lint_out" == *H019* ]]; check $? 0 "lint warns while the budgets are transitional"

# --- correction 2 of 1.1: sensors have to be versioned, and reach a clone
[ -x .githooks/pre-commit ]; check $? 0 "pre-commit installed in tracked .githooks"
check "$(git config --local --get core.hooksPath)" ".githooks" "core.hooksPath points at .githooks"
grep -q "core.hooksPath .githooks" package.json; check $? 0 "package.json prepare arms the hooks"
grep -q "core.hooksPath .githooks" AGENTS.md; check $? 0 "entry file documents how to arm the hooks"
[ -f .github/workflows/harness.yml ]; check $? 0 "CI workflow installed"
grep -q "code_sensor.py" .github/workflows/harness.yml; check $? 0 "CI runs the code sensor"
grep -q "hashFiles('.harness/scripts/code_sensor.py')" .github/workflows/harness.yml; check $? 0 "CI step keys off the sensor, not the baseline"
python3 -c "import json;c=json.load(open('.harness/config.json'));assert c['code_sensor']['format']=='eslint-json',c"; check $? 0 "eslint detected from package.json"
grep -q "code_sensor.py --staged" .githooks/pre-commit; check $? 0 "pre-commit runs the code sensor"

# --- the sensor is a ratchet, and works with any tool that lists problems per file
python3 - <<'PY'
import json
c = json.load(open(".harness/config.json"))
c["code_sensor"] = {"command": "python3 lintstub.py", "format": "text", "baseline": ".harness/code-baseline.json"}
json.dump(c, open(".harness/config.json", "w"), indent=2)
PY
python3 .harness/scripts/code_sensor.py >/dev/null; check $? 0 "sensor creates the baseline on first run"
python3 -c "import json;b=json.load(open('.harness/code-baseline.json'));assert b=={'src/a.js':2,'src/b.js':1},b"; check $? 0 "baseline counts problems per file"
python3 .harness/scripts/code_sensor.py >/dev/null; check $? 0 "sensor passes with pre-existing problems"
printf 'src/a.js:3:1: error x\nsrc/a.js:9:2: error y\nsrc/a.js:12:2: error w\nsrc/b.js:1:1: error z\n' > lintstub.txt
python3 .harness/scripts/code_sensor.py >/dev/null; check $? 1 "sensor fails when one file gets worse"
printf 'src/b.js:1:1: error z\n' > lintstub.txt
python3 .harness/scripts/code_sensor.py >/dev/null; check $? 0 "sensor passes when a file improves"
python3 -c "import json;b=json.load(open('.harness/code-baseline.json'));assert b=={'src/a.js':2,'src/b.js':1},b"; check $? 0 "improvement does NOT rewrite the baseline on its own"
python3 .harness/scripts/code_sensor.py | grep -q -- "--update-baseline"; check $? 0 "sensor tells the user how to consolidate an improvement"
python3 .harness/scripts/code_sensor.py --update-baseline >/dev/null; check $? 0 "explicit --update-baseline succeeds"
python3 -c "import json;b=json.load(open('.harness/code-baseline.json'));assert b=={'src/b.js':1},b"; check $? 0 "baseline tightens only when the user asks"
python3 - <<'PY'
import json
c = json.load(open(".harness/config.json")); c.pop("code_sensor")
json.dump(c, open(".harness/config.json", "w"), indent=2)
PY
python3 .harness/scripts/code_sensor.py >/dev/null; check $? 2 "sensor reports misconfiguration instead of passing"
rm -f .harness/code-baseline.json lintstub.txt

mkdir -p docs/references .harness/rules
git mv docs/big.md docs/references/big.md
python3 - <<'PY'
p="docs/references/big.md"; s=open(p).read()
open(p,"w").write("---\ndescription: Big reference\nread_when: deep dives\nstatus: active\nupdated: 2026-09-17\n---\n"+s)
open(".harness/rules/api.md","w").write('---\ndescription: API rules\npaths:\n  - "src/api/**"\n---\n- validate\n')
open("CLAUDE.md","w").write("@AGENTS.md\n\n## Claude Code\n- plan mode for billing\n")
PY
git rm -q .claude/rules/api.md
python3 .harness/scripts/sync.py >/dev/null && python3 .harness/scripts/build_index.py >/dev/null
echo "## [2026-09-17] audit | restructured" >> docs/log.md
python3 .harness/scripts/lint.py >/dev/null; check $? 0 "lint clean after restructure"
git add -A && git commit -qm restructure; check $? 0 "tracked pre-commit passes a clean commit (sensor unconfigured does not block)"

printf '# no frontmatter\n' > docs/references/new.md
printf '%s' "{\"session_id\":\"a\",\"cwd\":\"$P\",\"tool_input\":{\"file_path\":\"$P/docs/references/new.md\"}}" | python3 .harness/scripts/hook.py --agent claude-code --event post-edit 2>/dev/null; check $? 2 "claude post-edit blocks bad doc"
printf '%s' "{\"session_id\":\"b\",\"cwd\":\"$P\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Add File: docs/references/new.md\\n*** End Patch\"}}" | python3 .harness/scripts/hook.py --agent codex --event post-edit 2>/dev/null; check $? 2 "codex post-edit blocks bad doc"
out=$(printf '%s' "{\"conversation_id\":\"c\",\"workspace_roots\":[\"$P\"],\"loop_count\":0}" | python3 .harness/scripts/hook.py --agent cursor --event stop)
case "$out" in *followup_message*) check 1 1 "cursor stop returns followup";; *) check 0 1 "cursor stop returns followup";; esac
printf '%s' "{\"session_id\":\"a\",\"cwd\":\"$P\",\"stop_hook_active\":true}" | python3 .harness/scripts/hook.py --agent claude-code --event stop 2>/dev/null; check $? 0 "claude stop loop guard"
git add docs/references/new.md; git commit -qm bad 2>/dev/null; check $? 1 "tracked pre-commit blocks bad doc"
rm -f docs/references/new.md; git reset -q

python3 .harness/scripts/measure.py snapshot --label after >/dev/null
cmp_out=$(python3 .harness/scripts/measure.py compare --before baseline --after after); [[ "$cmp_out" == *claude-code* ]]; check $? 0 "before/after comparison"
# --- 1.5 / F7: --update-lock mid-migration must NOT freeze the half-migrated state
mid_out=$(python3 .harness/scripts/lint.py --update-lock)
[[ "$mid_out" != *"Transitional budgets closed:"* ]]; check $? 0 "--update-lock alone does not close the transitional budgets"
[[ "$mid_out" == *"--close-transitional"* ]]; check $? 0 "--update-lock says which flag closes them, and when"
python3 -c "import json;c=json.load(open('.harness/config.json'));assert 'budgets_transitional' in c, c"; check $? 0 "the transitional mark survives a plain --update-lock"
close_out=$(python3 .harness/scripts/lint.py --update-lock --close-transitional)
[[ "$close_out" == *"Transitional budgets closed:"* ]]; check $? 0 "--close-transitional reports what it tightens"
[[ "$close_out" == *"entry_file_lines:"* && "$close_out" == *"claude-code:"* ]]; check $? 0 "--update-lock prints before/after per budget and per agent"
python3 -c "import json;c=json.load(open('.harness/config.json'));assert 'budgets_transitional' not in c, c" ; check $? 0 "transitional mark cleared after the tightening"
[[ "$(python3 .harness/scripts/lint.py 2>/dev/null)" != *H019* ]]; check $? 0 "H019 gone once the budgets are real"
python3 .harness/scripts/lint.py --update-lock --close-transitional >/dev/null; printf '\n%s' "$(python3 -c 'print("\n".join("- extra line with plenty of words to grow tokens "*2 for _ in range(60)))')" >> AGENTS.md
lint_out=$(python3 .harness/scripts/lint.py 2>/dev/null); [[ "$lint_out" == *H015* ]]; check $? 0 "ratchet detects growth"

# --- 1.2 correction 1: a stale branch must stop the audit before it measures anything
U="$T/upstream"; W="$T/work"
git init -q --bare "$U"
git clone -q "$U" "$W" && git -C "$W" config user.email t@t && git -C "$W" config user.name t
echo one > "$W/a.txt" && git -C "$W" add -A && git -C "$W" commit -qm one && git -C "$W" push -q origin HEAD:main
git -C "$W" branch -q --set-upstream-to=origin/main 2>/dev/null
O="$T/other"; git clone -q "$U" "$O" && git -C "$O" config user.email t@t && git -C "$O" config user.name t
for i in 1 2 3; do echo "$i" > "$O/f$i.txt"; git -C "$O" add -A; git -C "$O" commit -qm "c$i"; done
git -C "$O" push -q origin HEAD:main && git -C "$W" fetch -q
b=$(python3 "$S/detect.py" --project "$W" --git-only | python3 -c "import json,sys;print(json.load(sys.stdin)['upstream']['behind'])")
check "$b" "3" "detect reports how many commits the branch is behind"
echo local > "$W/local.txt" && git -C "$W" add -A && git -C "$W" commit -qm local
div=$(python3 "$S/detect.py" --project "$W" --git-only | python3 -c "import json,sys;d=json.load(sys.stdin)['upstream'];print(d['diverged'],d['ahead'])")
check "$div" "True 1" "detect reports divergence without proposing a fix"
ref=$(python3 "$S/detect.py" --project "$P" --git-only | python3 -c "import json,sys;print(json.load(sys.stdin)['upstream']['reference'])")
check "$ref" "None" "no upstream and no origin/HEAD is recorded, not fatal"

# --- 1.2 correction 3: a git wrapper on PATH must not be what the scripts parse
FAKE="$T/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh
echo "wrapper output that no parser understands"
' > "$FAKE/git" && chmod +x "$FAKE/git"
wrapped=$(PATH="$FAKE:$PATH" python3 "$S/detect.py" --project "$W" --git-only)
python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
assert d['upstream']['behind'] == 3, d['upstream']
assert d['branch'] and 'wrapper output' not in json.dumps(d), d
assert d['git_environment']['wrapper_suspected'] is True, d['git_environment']
assert d['git_environment']['note'], d['git_environment']" <<<"$wrapped"; check $? 0 "scripts read the real git binary and flag the wrapper"

# --- 1.3: an unclean tree is surveyed, read-only, before anyone is asked to clean it
D="$T/dirty"; mkdir -p "$D" && git init -q "$D" && git -C "$D" config user.email t@t && git -C "$D" config user.name t
printf '# P\n' > "$D/CLAUDE.md" && git -C "$D" add -A && git -C "$D" commit -qm init
sub_state=$(python3 "$REPO/tests/dirty_fixture.py" "$D")
before=$(git -C "$D" status --porcelain --untracked-files=all; git -C "$D" stash list)
survey=$(python3 "$S/dirty.py" --project "$D")
after=$(git -C "$D" status --porcelain --untracked-files=all; git -C "$D" stash list)
check "$after" "$before" "the survey changes nothing in the working tree"
python3 "$REPO/tests/assert_dirty.py" "$sub_state" <<<"$survey"; check $? 0 "survey reports cache, modified, untracked and stash with evidence"
case "$sub_state" in submodule=yes) echo "PASS submodule pointer surveyed with its commits and tags";;
  *) echo "SKIP submodule: ${sub_state#submodule=skipped: } (test it by hand)";; esac
grep -qE 'SECRET-(STASH|NAME|COMMIT)-VALUE' <<<"$survey"; check $? 1 "survey leaks no secret from a stash message, a filename or a submodule commit"
grep -q '"path": "node_modules/"' <<<"$survey"; check $? 0 "cache is grouped by root directory, not listed file by file"
python3 "$S/detect.py" --project "$D" --git-only | grep -q '"dirty"'; check $? 0 "--git-only carries the survey, so apply sees it too"
slow=$(HARNESS_DIRTY_SLOW_SECONDS=0 python3 "$S/dirty.py" --project "$D")
python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['degraded'], d
assert d['modified'] == [] and d['modified_total'] == 1 and d['modified_omitted'] == 1, d
assert d['stashes'] == [] and d['stashes_total'] == 1, d" <<<"$slow"; check $? 0 "a slow survey degrades to counts instead of items"

# --- 1.2 correction 1: no fetch, so the answer has to carry its own age
git -C "$W" reset -q --hard origin/main && git -C "$W" fetch -q
fresh=$(python3 "$S/detect.py" --project "$W" --git-only | python3 -c "import json,sys;u=json.load(sys.stdin)['upstream'];print(u['behind'],u['stale_comparison'])")
check "$fresh" "0 False" "a freshly fetched reference produces no staleness note"
python3 -c "
import os, time, pathlib, subprocess
d = subprocess.run(['/usr/bin/git','-C','$W','rev-parse','--git-dir'],capture_output=True,text=True).stdout.strip()
p = pathlib.Path(d if os.path.isabs(d) else '$W/'+d)/'FETCH_HEAD'
old = time.time() - 3*86400
os.utime(p, (old, old))"
stale=$(python3 "$S/detect.py" --project "$W" --git-only | python3 -c "import json,sys;u=json.load(sys.stdin)['upstream'];print(u['behind'],u['stale_comparison'],u['reference_age_days'])")
check "$stale" "0 True 3" "behind 0 against an old reference is flagged as a stale comparison"

# --- correction 2 of 1.1: an existing hook setup is never taken over silently
H="$T/husky"; mkdir -p "$H/.husky" && git -C "$H" init -q && git -C "$H" config user.email t@t && git -C "$H" config user.name t
git -C "$H" config core.hooksPath .husky && printf '#!/bin/sh\nnpm test\n' > "$H/.husky/pre-commit"
python3 "$S/install.py" --project "$H" --agents claude-code --with-precommit --apply >/dev/null
grep -q "harness-audit" "$H/.husky/pre-commit"; check $? 0 "husky: hook installed into the configured hooksPath"
[ ! -d "$H/.githooks" ]; check $? 0 "husky: .githooks not imposed"
check "$(git -C "$H" config --local --get core.hooksPath)" ".husky" "husky: core.hooksPath left untouched"
grep -q "npm test" "$H/.husky/pre-commit"; check $? 0 "husky: existing hook content preserved"

G="$T/legacy"; mkdir -p "$G" && git -C "$G" init -q && git -C "$G" config user.email t@t && git -C "$G" config user.name t
printf '#!/bin/sh\necho mine\n' > "$G/.git/hooks/pre-commit" && chmod +x "$G/.git/hooks/pre-commit"
gout=$(python3 "$S/install.py" --project "$G" --agents claude-code --with-precommit --apply)
case "$gout" in *"SKIP   pre-commit"*) check 1 1 "legacy hooks: install warns instead of taking over";; *) check 0 1 "legacy hooks: install warns instead of taking over";; esac
[ -z "$(git -C "$G" config --local --get core.hooksPath)" ]; check $? 0 "legacy hooks: core.hooksPath not set"
grep -q "harness-audit" "$G/.git/hooks/pre-commit"; check $? 1 "legacy hooks: existing hook untouched"

# --- correction 3: user runtime is inventoried, and no secret ever reaches the report
FH="$T/home"
mkdir -p "$FH/.claude/agents" "$FH/.claude/plugins/marketplaces/mkt" \
         "$FH/.claude/plugins/cache/mkt/realplug/1.0.0/agents" \
         "$FH/.claude/plugins/cache/mkt/realplug/1.0.0/hooks"
python3 "$REPO/tests/fake_home.py" "$FH"
inv=$(HOME="$FH" python3 "$S/inventory.py" --project "$P" --include-user)
grep -q '"realplug@mkt"' <<<"$inv"; check $? 0 "inventory lists enabled plugins"
grep -q '"installed": false' <<<"$inv"; check $? 0 "inventory marks an enabled plugin missing from disk"
grep -q 'catalogonly' <<<"$inv"; check $? 1 "inventory ignores marketplace catalogs"
grep -q 'offplug' <<<"$inv"; check $? 1 "inventory ignores disabled plugins"
grep -q '1.0.0.bak' <<<"$inv"; check $? 1 "inventory ignores .bak copies"
grep -q 'reviewer' <<<"$inv" && grep -q 'planner' <<<"$inv"; check $? 0 "inventory lists user and plugin agents"
grep -q '"supabase"' <<<"$inv" && grep -q '"plugmcp"' <<<"$inv"; check $? 0 "inventory lists MCP server names"
grep -q 'plugboot.mjs' <<<"$inv"; check $? 0 "inventory lists SessionStart hook commands"
grep -qE 'SECRET-(ENV|HEADER|CMD|PLUGIN)-VALUE' <<<"$inv"; check $? 1 "inventory leaks no secret from env, headers or hook commands"
grep -q 'secret-host.example.com' <<<"$inv"; check $? 1 "inventory leaks no MCP server URL"
grep -q 'api-token=\*\*\*' <<<"$inv"; check $? 0 "inventory masks token pairs in hook commands"
HOME="$FH" python3 "$REPO/tests/assert_inventory.py" "$S/inventory.py" "$P"; check $? 0 "inventory clips hook commands and calls itself a lower bound"
# A project under HOME walks up to HOME, where .claude/CLAUDE.md is the user memory file.
mkdir -p "$FH/work/proj" && printf '# user memory\n' > "$FH/.claude/CLAUDE.md"
umem() { HOME="$FH" python3 "$S/inventory.py" --project "$FH/work/proj" "$@" | python3 -c "
import json,sys
print(sum(x['kind'] == 'memory-file' for x in json.load(sys.stdin)['agents']['claude-code']['always_on']))"; }
check "$(umem)" 0 "user memory stays out of the project walk without --include-user"
check "$(umem --include-user)" 1 "user memory counted once with --include-user"
rm "$FH/.claude/CLAUDE.md"

# --- 1.4: which instruction file each agent actually reads, and the silent failures
R="$T/resolution"; RH="$T/reshome"; mkdir -p "$R/.claude" "$RH/.claude"
git init -q "$R" && git -C "$R" config user.email t@t && git -C "$R" config user.name t
printf '# team\n- one shared rule\n' > "$R/AGENTS.md"
# HARNESS_MANAGED_SETTINGS keeps the test off the machine's real managed policy file.
export HARNESS_MANAGED_SETTINGS="$RH/managed.json"
res() { HOME="$RH" python3 "$S/inventory.py" --project "$R" "$@" 2>/dev/null; }
reslint() { HOME="$RH" python3 "$S/lint.py" --project "$R" 2>/dev/null; }

res | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d['instruction_resolution']; c=d['agents']['claude-code']
assert r['agents_md_read'] == 'undetermined', r['agents_md_read']
assert 'undetermined' in r['effective']['claude-code'], r['effective']
assert '/config' in r['effective']['claude-code'] and 'AGENTS.md loaded' in r['effective']['claude-code'], r['effective']
kinds = [(x['kind'], x['est_tokens']) for x in c['conditional']]
assert ('agents-md-direct', 6) in kinds, kinds
assert c['always_on_est_tokens'] == 0, c['always_on_est_tokens']
assert any('Outside the always-on total' in n for n in c['notes']), c['notes']"
check $? 0 "an unconfirmable direct read is undetermined and stays out of the always-on total"

printf 'my own notes\n' > "$R/CLAUDE.local.md"
res --include-user | python3 -c "
import json,sys
r=json.load(sys.stdin)['instruction_resolution']
assert r['agents_md_read'] == 'no', r
assert r['claude_local_md'] == ['CLAUDE.local.md'], r['claude_local_md']
assert 'CLAUDE.local.md only' in r['effective']['claude-code'], r['effective']
assert r['effective']['codex'] == 'AGENTS.md', r['effective']"
check $? 0 "a personal CLAUDE.local.md flips claude-code off AGENTS.md while codex still reads it"
out=$(reslint); [[ "$out" == *H020* ]]; check $? 0 "H020 warns that the team's AGENTS.md is off for this person only"
[[ "$out" == *"claude-md-and-agents-md"* && "$out" == *"@AGENTS.md"* ]]; check $? 0 "H020 gives both ways out"

printf '{"pluginConfigs":{"agents-md@builtin":{"options":{"instructionFiles":"claude-md"}}}}' > "$R/.claude/settings.json"
res --include-user | python3 -c "
import json,sys
r=json.load(sys.stdin)['instruction_resolution']
assert r['instruction_files'] == 'claude-md-or-agents-md', r
assert r['instruction_files_source'] == 'default', r['instruction_files_source']"
check $? 0 "instructionFiles in project settings is ignored, as Claude Code ignores it"
printf '{"pluginConfigs":{"agents-md@builtin":{"options":{"instructionFiles":"claude-md-and-agents-md"}}},"claudeMdExcludes":["**/other-team/CLAUDE.md"]}' > "$RH/.claude/settings.json"
res --include-user | python3 -c "
import json,sys
r=json.load(sys.stdin)['instruction_resolution']
assert r['instruction_files'] == 'claude-md-and-agents-md', r['instruction_files']
assert r['instruction_files_source'].endswith('.claude/settings.json'), r['instruction_files_source']
assert [x['scope'] for x in r['claude_md_excludes']] == ['user'], r['claude_md_excludes']"
check $? 0 "instructionFiles and claudeMdExcludes are read from user settings"
[[ "$(reslint)" != *H020* ]]; check $? 0 "H020 is silent once Project instructions loads both files"

printf 'codex only\n' > "$R/AGENTS.override.md"
[[ "$(reslint)" == *H022* ]]; check $? 0 "H022 flags the file Codex reads and Claude Code never does"
res --include-user | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['instruction_resolution']['agents_override_md'] == 'AGENTS.override.md', d['instruction_resolution']
codex = [x['path'] for x in d['agents']['codex']['always_on']]
claude = [x['path'] for x in d['agents']['claude-code']['always_on'] + d['agents']['claude-code']['conditional']]
assert codex == ['AGENTS.override.md'], codex
assert 'AGENTS.override.md' not in claude, claude"
check $? 0 "AGENTS.override.md is counted in the Codex always-on and nowhere in claude-code"
python3 -c "
import sys; sys.path.insert(0, '$S')
import lint
assert 'AGENTS.override.md' not in lint.ENTRY, lint.ENTRY
assert lint.is_harness_file(__import__('pathlib').Path('$R'), {'docs_dir': 'docs', 'index': {}}, 'AGENTS.override.md')"
check $? 0 "the override stays out of the Claude entry-file budget but is still linted"

B="$T/bigmd"; mkdir -p "$B" && git init -q "$B" && git -C "$B" config user.email t@t && git -C "$B" config user.name t
python3 -c "
with open('$B/CLAUDE.md','w') as fh:
    fh.write('# big\n'); fh.truncate(4*1024*1024 + 1)"
out=$(HOME="$RH" python3 "$S/lint.py" --project "$B" 2>/dev/null)
[[ "$out" == *H021* && "$out" == *"skips a CLAUDE.md over 4 MiB"* ]]; check $? 0 "H021 errors on a CLAUDE.md the agent ignores whole"
unset HARNESS_MANAGED_SETTINGS

# ================================ 1.5: the third pilot's findings ================================

# --- F1: the estimator is a floor with a knob, and the knob comes from a real measurement
python3 -c "
import sys; sys.path.insert(0, '$S')
import hlib
assert hlib.estimate_tokens('x' * 400) == 100, 'default ratio must stay 4.00'
assert hlib.estimate_tokens('x' * 420, ratio=2.10) == 200, hlib.estimate_tokens('x' * 420, ratio=2.10)
b = hlib.DEFAULT_CONFIG['budgets']
assert 'chars_per_token' in b and 'context_window' in b, b
assert '4.00' in hlib.ratio_note({}) and 'floor' in hlib.ratio_note({}), hlib.ratio_note({})
assert 'calibrated' in hlib.ratio_note({'budgets': {'chars_per_token': 2.1}}), 'calibrated note'"
check $? 0 "estimate_tokens keeps 4.00 by default and honours a calibrated ratio"

C="$T/calib"; mkdir -p "$C" && git init -q "$C" && git -C "$C" config user.email t@t && git -C "$C" config user.name t
python3 -c "open('$C/CLAUDE.md','w').write('# m\n' + 'palavra ' * 5000)"
python3 "$S/install.py" --project "$C" --agents claude-code --apply >/dev/null
# Feed it a /context number that is exactly half the characters it reads, so the ratio it
# must come back with is 2.00 and nothing about the fixture's size is baked into the test.
chars=$(HOME="$T/emptyhome" python3 "$S/measure.py" calibrate --project "$C" --manual '{"context_memory_files_tokens": 1}' \
        | sed -n 's/.*(\([0-9]*\) characters).*/\1/p')
cal=$(HOME="$T/emptyhome" python3 "$S/measure.py" calibrate --project "$C" --manual "{\"context_memory_files_tokens\": $((chars / 2))}" --apply)
[[ "$cal" == *"Measured ratio: 2.00"* ]]; check $? 0 "calibrate derives the ratio from a real /context number"
python3 -c "import json;c=json.load(open('$C/.harness/config.json'));assert c['budgets']['chars_per_token']==2.0,c['budgets']"; check $? 0 "calibrate writes budgets.chars_per_token"
[[ "$cal" == *"--update-lock"* ]]; check $? 0 "calibrate warns that every estimate just grew and the ratchet needs re-basing"
HOME="$T/emptyhome" python3 "$S/measure.py" calibrate --project "$C" >/dev/null; check $? 2 "calibrate refuses to guess without a measured number"

# --- F4: always-on over the model's context window is a hard failure, not a budget overrun
python3 -c "
import json;p='$C/.harness/config.json';c=json.load(open(p))
c['budgets']['context_window']=200; c['budgets']['always_on_tokens']=100
json.dump(c,open(p,'w'),indent=2)"
win=$(python3 "$S/lint.py" --project "$C" 2>/dev/null)
[[ "$win" == *"does not open on that model at all"* ]]; check $? 0 "H002 names the hard failure when always-on exceeds the window"
python3 -c "
import json;p='$C/.harness/config.json';c=json.load(open(p))
c['budgets']['context_window']=None
json.dump(c,open(p,'w'),indent=2)"
[[ "$(python3 "$S/lint.py" --project "$C" 2>/dev/null)" == *"floor,"* ]]; check $? 0 "without a window, H002 says the estimate is a floor and which ratio made it"

# --- F2: a vault folder named like part of the project is found, and [] is never the whole answer
V="$T/vault"; mkdir -p "$V/.obsidian" "$V/B01 Projetos/tavoloo" "$V/A00 inbox"
PJ="$T/tavoloo-fmsolutions-main"; mkdir -p "$PJ" && git init -q "$PJ"
python3 "$S/detect.py" --project "$PJ" --search "$V" | python3 -c "
import json,sys
v=[x for x in json.load(sys.stdin)['obsidian_vaults_found'] if x['path'].endswith('/vault')]
assert v, 'vault not found at all'
assert v[0]['folders_named_like_project'] == ['B01 Projetos/tavoloo'], v[0]['folders_named_like_project']
assert 'A00 inbox' in v[0]['top_level_folders'], v[0]['top_level_folders']"
check $? 0 "detect matches tavoloo against tavoloo-fmsolutions-main and lists the vault's top level"
python3 -c "
import sys; sys.path.insert(0, '$S')
import detect
assert detect.name_tokens('my-api-web') == {'my-api-web'}, detect.name_tokens('my-api-web')"
check $? 0 "tokens under 4 characters are not matched on"

# --- F3: shared paragraphs between entry files of different sizes are a fork, not double payment
K="$T/fork"; mkdir -p "$K" && git init -q "$K"
python3 -c "
para = ('A shared paragraph, long enough to be counted as duplicated instruction content between two '
        'entry files of this fixture project, which needs more than a hundred and twenty characters.')
open('$K/CLAUDE.md','w').write('# p\n\n' + para + '\n\n' + '\n'.join('- line %d' % i for i in range(400)))
open('$K/AGENTS.md','w').write('# p\n\n' + para + '\n')"
fork_out=$(python3 "$S/lint.py" --project "$K" 2>/dev/null)
[[ "$fork_out" == *H023* && "$fork_out" != *H011* ]]; check $? 0 "H023 replaces H011 when the two entry files have forked"
[[ "$fork_out" == *"older truth"* ]]; check $? 0 "H023 says who is running on the stale side"
python3 -c "
para = ('A shared paragraph, long enough to be counted as duplicated instruction content between two '
        'entry files of this fixture project, which needs more than a hundred and twenty characters.')
open('$K/CLAUDE.md','w').write('# p\n\n' + para + '\n')"
[[ "$(python3 "$S/lint.py" --project "$K" 2>/dev/null)" == *H011* ]]; check $? 0 "H011 still fires when the content really is paid twice"

# --- F8: application syntax is not a broken wikilink, and a project can suppress a code
mkdir -p "$K/docs/architecture" "$K/.harness"
python3 -c "
open('$K/docs/architecture/edge.md','w').write(
    '---\ndescription: d\nupdated: 2026-09-20\nstatus: active\n---\n'
    'The concierge emits [[PRODUCT:<uuid>|name]] and [[missing-note]].\n')"
wl=$(python3 "$S/lint.py" --project "$K" 2>/dev/null)
[[ "$wl" != *PRODUCT* ]]; check $? 0 "H017 ignores a wikilink that is machine syntax, not a note reference"
[[ "$wl" == *missing-note* ]]; check $? 0 "H017 still reports a wikilink that really is broken"
printf '{"lint": {"suppress": {"H017": ["missing-note"]}}}' > "$K/.harness/config.json"
[[ "$(python3 "$S/lint.py" --project "$K" 2>/dev/null)" != *missing-note* ]]; check $? 0 "lint.suppress silences a code the project decided not to fix"

# --- F13 (slice): no lock means the ratchet compares nothing, and must not pass in silence
printf '{"ratchet": true}' > "$K/.harness/config.json"
rm -f "$K/.harness/budgets.lock.json"
noloc=$(python3 "$S/lint.py" --project "$K" 2>/dev/null)
[[ "$noloc" == *H024* && "$noloc" == *"no baseline"* ]]; check $? 0 "H024 reports a ratchet with nothing to compare against"
[[ "$(python3 .harness/scripts/lint.py 2>/dev/null)" != *H024* ]]; check $? 0 "H024 is silent once a lock exists"

# --- F11/F6: the benchmark environment proves its commit, or the battery does not start
git -C "$P" add -A && git -C "$P" commit -qm "benchmark starting point" >/dev/null
python3 "$S/benchenv.py" --dir "$P" --main "$P" >/dev/null 2>&1; check $? 1 "benchenv refuses the main working tree"
audit_commit=$(git -C "$P" rev-parse HEAD)
git -C "$P" worktree add -q "$T/wt-good" HEAD
git -C "$P" worktree add -q --detach "$T/wt-old" "$(git -C "$P" rev-list --max-parents=0 HEAD)"
python3 "$S/benchenv.py" --dir "$T/wt-good" --commit "$audit_commit" --main "$P" >/dev/null; check $? 0 "benchenv passes a worktree that contains the audit commit"
bad=$(python3 "$S/benchenv.py" --dir "$T/wt-old" --commit "$audit_commit" --main "$P" 2>&1); check $? 1 "benchenv aborts a worktree born before the audit commit"
[[ "$bad" == *"describes the old harness"* ]]; check $? 0 "benchenv says why the numbers from there would be worthless"
python3 "$S/benchenv.py" --dir "$T/wt-good" --commit "$audit_commit" --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['separate_worktree'] is True, d
assert d['commit_is_ancestor'] is True, d
assert d['artefacts']['entry_file_lines'], d['artefacts']
assert 'docs_dir_exists' in d['artefacts'] and 'scoped_rules' in d['artefacts'], d['artefacts']"
check $? 0 "benchenv proves the state by observable artefact, not by the commit id alone"
echo stray > "$P/stray.txt"
python3 "$S/benchenv.py" --dir "$T/wt-good" --commit "$audit_commit" --main "$P" >/dev/null 2>&1; check $? 1 "benchenv catches a task that wrote into the main tree"
rm -f "$P/stray.txt"
[ -f "$P/.harness/scripts/benchenv.py" ]; check $? 0 "benchenv.py is installed into the project with the other scripts"

# --- F10: a big always-on reduction with a flat per-task cost stops the battery
python3 -c "
import json, pathlib
r = pathlib.Path('$P/.harness/reports')
b = json.loads((r / 'baseline.json').read_text())
a = json.loads((r / 'after.json').read_text())
for agent in b['agents']:
    b['agents'][agent]['always_on_est_tokens'] = 100000
    a['agents'].setdefault(agent, dict(b['agents'][agent]))['always_on_est_tokens'] = 2000
a['manual'] = {'tasks': [{'id': 'T3', 'tokens_before': 41000, 'tokens_after': 40000,
                          'tool_uses_before': 12, 'tool_uses_after': 12},
                         {'id': 'T4', 'tokens_before': 30000, 'tokens_after': 30500}]}
(r / 'flat-before.json').write_text(json.dumps(b))
(r / 'flat-after.json').write_text(json.dumps(a))
a['manual'] = {'tasks': [{'id': 'T3', 'tokens_before': 41000, 'tokens_after': 12000}]}
(r / 'cheap-after.json').write_text(json.dumps(a))"
flat=$(python3 .harness/scripts/measure.py compare --before flat-before --after flat-after); check $? 2 "compare exits 2 when the cost does not match the reduction"
[[ "$flat" == *"cannot both be right"* && "$flat" == *benchenv* ]]; check $? 0 "the refusal names the likely cause and the tool that settles it"
[[ "$flat" == *"| T3 |"* && "$flat" == *"Tool uses before"* ]]; check $? 0 "the comparison carries tokens and tool uses per task"
python3 .harness/scripts/measure.py compare --before flat-before --after cheap-after >/dev/null; check $? 0 "a cost that follows the reduction passes"
quiet=$(python3 .harness/scripts/measure.py compare --before baseline --after after); check $? 0 "a comparison with no task numbers still succeeds"
[[ "$quiet" == *"behavioural half of this comparison was not measured"* ]]; check $? 0 "but it says the behavioural half was not measured, instead of passing in silence"
[[ "$quiet" == *"chars/token"* ]]; check $? 0 "the comparison states which chars/token ratio produced the estimates"

# --- F12: the verify must never tell the agent to rerun the benchmark itself
SK="$REPO/skills/harness-audit/SKILL.md"
grep -q "rerun them in fresh sessions and record success" "$SK"; check $? 1 "verify no longer orders the agent to rerun the benchmark"
grep -q "you cannot open a fresh session" "$SK"; check $? 0 "verify says in one sentence why it cannot measure the behavioural half"
grep -q "The tasks are run by the user" "$SK"; check $? 0 "diagnose names who runs the benchmark on the before side too"
grep -q "the user, in a fresh session, on both sides" "$REPO/skills/harness-audit/references/rubric.md"; check $? 0 "the rubric names the actor instead of just the session"
for rd in "$REPO/README.md" "$REPO/README.pt-BR.md"; do
  grep -qiE "verify.{0,40}(reruns them|repete essas)" "$rd"; check $? 1 "$(basename "$rd") does not promise that verify reruns the benchmark"
done

# --- F9: the command-guard requirements are written down, as project requirements
grep -q "heredocs and quoted content before matching" "$SK"; check $? 0 "SKILL.md requires the guard to match the command, not the string"
grep -q "installs no command guard itself" "$SK"; check $? 0 "SKILL.md says the guard belongs to the project, not to this skill"

cmp -s "$REPO/skills/harness-keeper/SKILL.md" "$REPO/skills/harness-audit/assets/templates/harness-keeper-skill.tmpl"; check $? 0 "keeper template matches skills/harness-keeper"
python3 "$REPO/tools/build_dist.py" >/dev/null; check $? 0 "dist packages build and validate"
n=$(python3 -c "import zipfile,sys;print(sum(1 for n in zipfile.ZipFile('$REPO/dist/harness-audit.zip').namelist() if n.split('/')[-1]=='SKILL.md'))"); check "$n" 1 "upload zip has exactly one SKILL.md"
rm -rf "$T"; [ $fail -eq 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
