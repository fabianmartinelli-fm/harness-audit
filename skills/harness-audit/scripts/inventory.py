#!/usr/bin/env python3
"""Map every harness layer per agent: always-on, conditional, on-demand.

Usage: python3 inventory.py [--project PATH] [--include-user] [--out FILE]
Loading rules reflect vendor docs as checked in Sept 2026 (see references/agents/*).
Token numbers are estimates; runtime truth comes from transcripts.py and /context.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

from hlib import (HOME, as_list, claude_code_version, docs_root, dump_json, enabled_agents, estimate_tokens,
                  find_project_root, git_environment, iter_md, load_config, parse_frontmatter, read_text, rel,
                  safe_command, version_tuple)

IMPORT_RE = re.compile(r"(?<![\w`])@((?:~|\.{1,2})?/?[\w.\-/~]+)")


def strip_code(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", text)


def item(root, path: Path, kind: str, text: str | None = None, note: str = "", **extra):
    text = read_text(path) if text is None else text
    d = {"path": rel(root, path), "kind": kind, "lines": text.count("\n") + (1 if text else 0),
         "bytes": len(text.encode("utf-8")), "est_tokens": estimate_tokens(text)}
    if note:
        d["note"] = note
    d.update(extra)
    return d


# ------------------------------------------------- instruction-file resolution
# Which instruction file each agent reads here is not readable from the repository
# alone. Claude Code reads AGENTS.md only when no CLAUDE.md, .claude/CLAUDE.md or
# CLAUDE.local.md sits in the working directory or above it, and the switch that
# changes that (instructionFiles) is honored only in user, managed and --settings
# files: Claude Code ignores it in project and local settings. A CLAUDE.local.md is
# personal and gitignored, so it turns the team's AGENTS.md off for one person while
# the repository still looks right. So the inventory states the outcome, not just the
# files: one line per agent saying what it actually loads in this project.
MANAGED_SETTINGS = tuple(Path(p) for p in os.environ.get("HARNESS_MANAGED_SETTINGS", "").split(os.pathsep) if p) or (
    Path("/Library/Application Support/ClaudeCode/managed-settings.json"),
    Path("/etc/claude-code/managed-settings.json"),
    Path(r"C:\Program Files\ClaudeCode\managed-settings.json"),
)
DEFAULT_MODE = "claude-md-or-agents-md"
CLAUDE_MD_NAMES = ("CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md")
AGENTS_MD_NAMES = ("AGENTS.md", ".claude/AGENTS.md")
AGENTS_MD_MIN_VERSION = "2.1.277"
USER_MEMORY = HOME / ".claude/CLAUDE.md"
NOT_READ = "not read (rerun with --include-user)"


def ancestors(root: Path):
    """The project root and every directory above it, stopping at HOME."""
    for p in [root, *root.parents]:
        yield p
        if p == HOME or p == p.parent:
            return


def instruction_files_setting(read_user: bool):
    """(value, source) for pluginConfigs['agents-md@builtin'].options.instructionFiles.

    Managed first, then user. Project and local settings are not consulted because
    Claude Code ignores the key there: reading them would report a value that has
    no effect.
    """
    if not read_user:
        return DEFAULT_MODE, NOT_READ
    for path in (*MANAGED_SETTINGS, HOME / ".claude/settings.json"):
        if not path.is_file():
            continue
        opts = ((_json(path).get("pluginConfigs") or {}).get("agents-md@builtin") or {}).get("options") or {}
        if opts.get("instructionFiles"):
            return str(opts["instructionFiles"]), str(path)
    return DEFAULT_MODE, "default"


def claude_md_excludes(root: Path, read_user: bool):
    """claudeMdExcludes from every layer that honors it. Arrays merge across layers."""
    out = []
    layers = [(root / ".claude/settings.json", "project"), (root / ".claude/settings.local.json", "local")]
    if read_user:
        layers = [(p, "managed") for p in MANAGED_SETTINGS] + [(HOME / ".claude/settings.json", "user")] + layers
    for path, scope in layers:
        if path.is_file():
            for pattern in _json(path).get("claudeMdExcludes") or []:
                out.append({"pattern": str(pattern), "scope": scope, "source": str(path)})
    return out


def imports_agents_md(path: Path) -> bool:
    return any(ref.rstrip("/").split("/")[-1] == "AGENTS.md"
               for ref in IMPORT_RE.findall(strip_code(read_text(path))))


# Direct reading of AGENTS.md also depends on things no file on disk records: which
# provider the session runs on and whether it fetched feature flags, whether it is the
# first session after an install or an upgrade, and whether the built-in agents-md
# plugin is enabled there. None of those can be read here, so a positive answer is
# never asserted: it is reported as undetermined with the two ways to settle it. A
# negative answer survives all of them, because nothing in that list ever makes Claude
# read a file it would otherwise skip.
UNKNOWABLE = (
    "the provider and whether the session fetches feature flags (Amazon Bedrock, another third-party "
    "provider or telemetry disabled never read AGENTS.md directly)",
    "whether this is the first session after installing or upgrading Claude Code",
    "whether the built-in agents-md plugin is enabled, and whether disableAllHooks or "
    "allowManagedHooksOnly is set for the session",
)
CONFIRM = (
    "/config in the session: the Project instructions value, and its absence means this session cannot "
    "read AGENTS.md at all",
    "the session line: no CLAUDE.md found; AGENTS.md loaded: <path>",
)


def instruction_resolution(root: Path, read_user: bool, agents=()) -> dict:
    mode, mode_source = instruction_files_setting(read_user)
    settings_read = read_user and mode_source != NOT_READ
    version = claude_code_version() if read_user else None
    blocking, local_only, agents_files, imported = [], [], [], []
    for p in ancestors(root):
        for name in CLAUDE_MD_NAMES:
            f = p / name
            if not f.is_file() or f.resolve() == USER_MEMORY.resolve():
                continue
            blocking.append(rel(root, f))
            if name == "CLAUDE.local.md":
                local_only.append(rel(root, f))
            if imports_agents_md(f):
                imported.append(rel(root, f))
        for name in AGENTS_MD_NAMES:
            if (p / name).is_file():
                agents_files.append(rel(root, p / name))
    override = rel(root, root / "AGENTS.override.md") if (root / "AGENTS.override.md").is_file() else None

    # Reasons direct reading is off that ARE visible from disk. Any one of them settles it.
    ruled_out = []
    if not agents_files:
        ruled_out.append("there is no AGENTS.md in the working directory or above it")
    if settings_read and mode in ("claude-md", "managed-only"):
        ruled_out.append(f"Project instructions is {mode}")
    if settings_read and mode == DEFAULT_MODE and blocking:
        ruled_out.append("the CLAUDE.md family is present: " + ", ".join(blocking))
    if version and version_tuple(version) < version_tuple(AGENTS_MD_MIN_VERSION):
        ruled_out.append(f"Claude Code {version} is older than v{AGENTS_MD_MIN_VERSION}")

    unknowns = []
    if not ruled_out:
        if not settings_read:
            unknowns.append("the Project instructions value (user and managed settings not read: rerun with "
                            "--include-user)")
        if not version:
            unknowns.append(f"the Claude Code version, which must be v{AGENTS_MD_MIN_VERSION} or later (no "
                            "readable claude binary on PATH)")
        unknowns.extend(UNKNOWABLE)
    agents_md_read = "no" if ruled_out else "undetermined"

    effective = {}
    for a in agents or ("claude-code",):
        if a == "claude-code":
            if agents_md_read == "undetermined":
                if blocking and not settings_read:
                    would = (f"{', '.join(blocking)} loads either way; {', '.join(agents_files)} is skipped under "
                             f"the default value and loaded after it under claude-md-and-agents-md")
                elif blocking:
                    would = (f"{', '.join(blocking)} loads, and {', '.join(agents_files)} after it "
                             f"(Project instructions {mode})")
                else:
                    would = (f"{', '.join(agents_files)} would be read directly: no CLAUDE.md, .claude/CLAUDE.md "
                             f"or CLAUDE.local.md in this tree switches it off")
                text = (f"undetermined for AGENTS.md. {would}. What is undetermined cannot be read from disk: " +
                        "; ".join(unknowns) + ". Confirm with " + " and ".join(CONFIRM))
            elif blocking and imported:
                text = f"{', '.join(blocking)}, with AGENTS.md through the @import in {', '.join(imported)}"
            elif blocking:
                text = f"{', '.join(blocking)} only" + (
                    "; AGENTS.md is not read directly because " + " and ".join(ruled_out) if agents_files else "")
            else:
                text = ("no project instruction file" if not agents_files else
                        "no project instruction file at launch: " + " and ".join(ruled_out))
            if settings_read and mode == "managed-only":
                text = "only the managed CLAUDE.md and auto memory (project, local, user and every AGENTS.md left out)"
        elif a == "codex":
            chain = override or (rel(root, root / "AGENTS.md") if (root / "AGENTS.md").is_file() else None)
            text = f"{chain} (AGENTS.override.md wins over AGENTS.md)" if override else (chain or "no project doc")
        elif a == "cursor":
            text = rel(root, root / "AGENTS.md") if (root / "AGENTS.md").is_file() else "no AGENTS.md; .cursor/rules only"
        else:
            names = [n for n in ("GEMINI.md", "AGENTS.md") if (root / n).is_file()]
            text = ", ".join(names) if names else "no context file"
        effective[a] = text

    notes = [
        "instructionFiles is honored in user, managed and --settings files only: a value in project or "
        "local settings has no effect and is not read here.",
        "Server-managed settings come from the claude.ai console and cannot be read from disk: a value "
        "deployed that way is not visible in this report, so a 'no' that rests on the setting can still be wrong.",
        "claudeMdExcludes is recorded, not applied to the estimates below; it also applies inside an "
        "AGENTS.md that Claude reads directly.",
    ]
    if agents_md_read == "undetermined":
        notes.append("An AGENTS.md read directly is NOT listed in /memory or under Memory files in /context, so "
                     "/context understates the always-on total by its size. InstructionsLoaded hooks do not fire "
                     "for it either. It is reported as conditional here and left out of always_on_est_tokens: a "
                     "total that moves with an assumption is worse than two numbers with their reason.")
    if agents_files and agents_md_read == "no":
        notes.append("AGENTS.md exists and is not read directly: " + " and ".join(ruled_out) + ".")
    return {
        "instruction_files": mode,
        "instruction_files_source": mode_source,
        "claude_code_version": version,
        "claude_md_files": blocking,
        "claude_local_md": local_only,
        "agents_md_files": agents_files,
        "agents_md_imported_by": imported,
        "agents_override_md": override,
        "claude_md_excludes": claude_md_excludes(root, read_user),
        "agents_md_read": agents_md_read,
        "ruled_out_because": ruled_out,
        "undetermined_because": unknowns,
        "confirm_with": list(CONFIRM),
        "effective": effective,
        "notes": notes,
    }


# ---------------------------------------------------------------- claude code
def claude_imports(root, path: Path, depth=0, seen=None):
    seen = seen if seen is not None else set()
    out = []
    if depth >= 4:
        return out
    for ref in IMPORT_RE.findall(strip_code(read_text(path))):
        if "/" not in ref and "." not in ref:
            continue
        target = Path(ref.replace("~", str(HOME), 1)) if ref.startswith("~") else (path.parent / ref)
        target = target.resolve()
        if target in seen or not target.is_file():
            continue
        seen.add(target)
        external = not str(target).startswith(str(root.resolve()))
        out.append(item(root, target, "import", note=f"imported by {rel(root, path)} (loads at launch)",
                        external=external))
        out.extend(claude_imports(root, target, depth + 1, seen))
    return out


def skill_listing(root, dirs, agent):
    always, hidden = [], []
    for d in dirs:
        if not d.is_dir():
            continue
        for sk in sorted(d.glob("*/SKILL.md")):
            fm, _ = parse_frontmatter(read_text(sk))
            desc = f"{fm.get('name', sk.parent.name)}: {fm.get('description', '')} {fm.get('when_to_use', '')}"
            entry = item(root, sk, "skill-description", text=desc, description_chars=len(str(fm.get("description", ""))))
            if agent == "claude-code" and fm.get("disable-model-invocation") is True:
                entry["note"] = "manual-only: description not in context"
                hidden.append(entry)
            else:
                always.append(entry)
    return always, hidden


def claude_layers(root: Path, include_user: bool, res: dict):
    always, cond = [], []
    candidates = []
    for p in ancestors(root):
        for name in ("CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"):
            # At HOME, .claude/CLAUDE.md IS the user memory: counts only with include_user.
            if (p / name).is_file() and (p / name).resolve() != USER_MEMORY.resolve():
                candidates.append(p / name)
    if include_user and USER_MEMORY.is_file():
        candidates.append(USER_MEMORY)
    seen = set()
    for c in candidates:
        if c.resolve() in seen:
            continue
        seen.add(c.resolve())
        always.append(item(root, c, "memory-file"))
        always.extend(claude_imports(root, c, seen=seen))
    # An AGENTS.md Claude reads directly costs the same as a CLAUDE.md and appears in
    # neither /memory nor /context, so it has to be visible somewhere. It is listed as
    # conditional, with the reason: whether the session really reads it cannot be settled
    # from disk, and a total that silently absorbs that guess is worse than two numbers.
    if res.get("agents_md_read") == "undetermined":
        for r in res["agents_md_files"]:
            p = (root / r) if not Path(r).is_absolute() else Path(r)
            if not p.is_file() or p.resolve() in seen:
                continue
            seen.add(p.resolve())
            cond.append(item(root, p, "agents-md-direct",
                             note="counts toward always-on only if direct reading is active in the session; "
                                  "left out of always_on_est_tokens while that is undetermined. Confirm with "
                                  "the line: no CLAUDE.md found; AGENTS.md loaded: <path>"))
            cond.extend(claude_imports(root, p, seen=seen))
    rule_dirs = [root / ".claude/rules"] + ([HOME / ".claude/rules"] if include_user else [])
    for rd in rule_dirs:
        for r in iter_md(rd):
            fm, _ = parse_frontmatter(read_text(r))
            if as_list(fm.get("paths")):
                cond.append(item(root, r, "rule-scoped", paths=as_list(fm.get("paths"))))
            else:
                always.append(item(root, r, "rule-unscoped", note="no paths: loads every session"))
    for sub in root.rglob("CLAUDE.md"):
        if sub.parent != root and ".git" not in sub.parts and "node_modules" not in sub.parts:
            cond.append(item(root, sub, "nested-memory", note="loads when files in this dir are read"))
    enc = "-" + str(root.resolve()).strip("/").replace("/", "-").replace(".", "-")
    mem = HOME / ".claude/projects" / enc / "memory/MEMORY.md"
    if mem.is_file():
        text = "\n".join(read_text(mem).splitlines()[:200])[:25000]
        always.append(item(root, mem, "auto-memory-index", text=text, note="first 200 lines / 25KB"))
    skill_dirs = [root / ".claude/skills"] + ([HOME / ".claude/skills"] if include_user else [])
    s_always, s_hidden = skill_listing(root, skill_dirs, "claude-code")
    always.extend(s_always)
    notes = ["Plugin skills, MCP server instructions and output styles also load; confirm with /context.",
             f"Instruction files resolved as: {res['effective'].get('claude-code', '')} "
             f"(Project instructions: {res['instruction_files']}, from {res['instruction_files_source']})."]
    if res["instruction_files_source"] not in (NOT_READ, "default") and res["instruction_files"] == "managed-only":
        notes.append("Project instructions is managed-only: the project, local and user files listed above are "
                     "NOT loaded at launch in this configuration, only the managed CLAUDE.md and auto memory.")
    pending = [x for x in cond if x["kind"] == "agents-md-direct"]
    if pending:
        notes.append("Outside the always-on total, pending confirmation: " +
                     ", ".join(f"{x['path']} ~{x['est_tokens']} tokens" for x in pending) +
                     f" (~{sum(x['est_tokens'] for x in pending)} tokens in all). Add them to the total if the "
                     "session shows the AGENTS.md loaded line; /context will not show them either way.")
    return always, cond, s_hidden, notes


# ---------------------------------------------------------------- codex
def codex_layers(root: Path, include_user: bool, cfg: dict):
    always, cond, notes = [], [], []
    cap = int(cfg["budgets"].get("codex_project_doc_bytes", 32768))
    if include_user:
        for n in ("AGENTS.override.md", "AGENTS.md"):
            if (HOME / ".codex" / n).is_file() and read_text(HOME / ".codex" / n).strip():
                always.append(item(root, HOME / ".codex" / n, "global-instructions"))
                break
    used = 0
    for n in ("AGENTS.override.md", "AGENTS.md"):
        p = root / n
        if p.is_file() and read_text(p).strip():
            e = item(root, p, "project-doc")
            used += e["bytes"]
            if used > cap:
                e["note"] = f"TRUNCATED: project doc chain exceeds {cap} bytes"
            always.append(e)
            break
    for sub in root.rglob("AGENTS.md"):
        if sub.parent != root and ".git" not in sub.parts and "node_modules" not in sub.parts:
            cond.append(item(root, sub, "nested-project-doc", note="loads only when Codex starts inside this dir"))
    s_always, _ = skill_listing(root, [root / ".agents/skills", root / ".codex/skills"] +
                                ([HOME / ".agents/skills", HOME / ".codex/skills"] if include_user else []), "codex")
    always.extend(s_always)
    notes.append(f"Codex caps the combined AGENTS.md chain at project_doc_max_bytes ({cap} bytes) and truncates silently.")
    notes.append("Codex has no @import: pointers must be plain paths the agent reads on demand.")
    return always, cond, [], notes


# ---------------------------------------------------------------- cursor
def cursor_layers(root: Path, include_user: bool):
    always, cond, notes = [], [], []
    if (root / "AGENTS.md").is_file():
        always.append(item(root, root / "AGENTS.md", "agents-md"))
    if (root / ".cursorrules").is_file():
        always.append(item(root, root / ".cursorrules", "legacy-cursorrules", note="deprecated: migrate to .cursor/rules"))
    for r in iter_md(root / ".cursor/rules"):
        text = read_text(r)
        if r.suffix != ".mdc":
            cond.append(item(root, r, "ignored-rule", note=".md in .cursor/rules is ignored; use .mdc"))
            continue
        fm, _ = parse_frontmatter(text)
        if fm.get("alwaysApply") is True:
            always.append(item(root, r, "rule-always"))
        elif as_list(fm.get("globs")):
            cond.append(item(root, r, "rule-globs", globs=as_list(fm.get("globs"))))
        elif fm.get("description"):
            always.append(item(root, r, "rule-agent-requested-description", text=str(fm.get("description"))))
            cond.append(item(root, r, "rule-agent-requested"))
        else:
            cond.append(item(root, r, "rule-manual"))
    s_always, _ = skill_listing(root, [root / ".cursor/skills"] + ([HOME / ".cursor/skills"] if include_user else []), "cursor")
    always.extend(s_always)
    notes.append("User Rules live in Cursor settings (not on disk) and always apply: review them manually.")
    return always, cond, [], notes


# ---------------------------------------------------------------- antigravity
def antigravity_layers(root: Path, include_user: bool):
    always, cond, notes = [], [], []
    if include_user and (HOME / ".gemini/GEMINI.md").is_file():
        always.append(item(root, HOME / ".gemini/GEMINI.md", "global-context"))
    for n in ("GEMINI.md", "AGENTS.md"):
        if (root / n).is_file():
            always.append(item(root, root / n, "context-file"))
    for r in iter_md(root / ".agents/rules"):
        always.append(item(root, r, "workspace-rule", note="assumed always-on; verify with agy inspect"))
    s_always, _ = skill_listing(root, [root / ".agents/skills"], "antigravity")
    always.extend(s_always)
    notes.append("Antigravity reads GEMINI.md literally (no @import expansion). Legacy Gemini CLI did expand @imports.")
    notes.append("If GEMINI.md and AGENTS.md both exist, their content is paid twice: keep one canonical.")
    return always, cond, [], notes


# ---------------------------------------------------------------- user runtime
# Plugins, custom agents, MCP servers and SessionStart hook output are always-on
# costs that never appear as files in the project. They are listed here so the
# baseline is not read as the whole story. Nothing in this section is executed,
# and no env value, header, URL or credential is ever written out.
SETTINGS_FILES = (".claude/settings.json", ".claude/settings.local.json", ".claude.json")


def _json(path: Path) -> dict:
    try:
        data = json.loads(read_text(path) or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def user_settings():
    return [(p, _json(p)) for p in (HOME / f for f in SETTINGS_FILES) if p.is_file()]


def plugin_dir(marketplace: str, name: str) -> Path | None:
    """Resolve an enabled plugin to its folder on disk.

    ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/ is the installed copy.
    ~/.claude/plugins/marketplaces/ holds catalogs of plugins that are NOT installed,
    and *.bak copies are leftovers: neither may be counted.
    """
    base = HOME / ".claude/plugins/cache" / marketplace / name
    if not base.is_dir():
        return None
    versions = sorted((d for d in base.iterdir() if d.is_dir() and not d.name.endswith(".bak")),
                      key=lambda d: d.name)
    return versions[-1] if versions else (base if (base / ".claude-plugin").is_dir() else None)


def enabled_plugins():
    """[(id, marketplace, name, dir or None)] for every plugin switched on in settings."""
    out, seen = [], set()
    for _, data in user_settings():
        for pid, on in (data.get("enabledPlugins") or {}).items():
            if on is not True or pid in seen:
                continue
            seen.add(pid)
            name, _, marketplace = str(pid).partition("@")
            out.append((pid, marketplace, name, plugin_dir(marketplace, name)))
    return sorted(out)


def mcp_servers(plugins):
    """Server NAMES only. Values carry env, headers and tokens and are never read."""
    found = []
    for path, data in user_settings():
        for name in (data.get("mcpServers") or {}):
            found.append({"name": name, "source": rel(HOME, path)})
    for pid, _, _, d in plugins:
        if d and (d / ".mcp.json").is_file():
            for name in (_json(d / ".mcp.json").get("mcpServers") or {}):
                found.append({"name": name, "source": f"plugin:{pid}"})
    return found


def custom_agents(root: Path, plugins):
    out = []
    for p in sorted(iter_md(HOME / ".claude/agents")):
        fm, _ = parse_frontmatter(read_text(p))
        desc = f"{fm.get('name', p.stem)}: {fm.get('description', '')}"
        out.append(item(root, p, "agent-description", text=desc, source="user"))
    for pid, _, _, d in plugins:
        if not d:
            continue
        for p in sorted(iter_md(d / "agents")):
            fm, _ = parse_frontmatter(read_text(p))
            desc = f"{fm.get('name', p.stem)}: {fm.get('description', '')}"
            out.append(item(root, p, "agent-description", text=desc, source=f"plugin:{pid}"))
    return out


def session_start_hooks(plugins):
    """SessionStart commands whose stdout is injected into every session. Never run."""
    out = []

    def collect(data: dict, source: str):
        for group in (data.get("hooks") or {}).get("SessionStart") or []:
            for h in group.get("hooks") or []:
                if h.get("command"):
                    out.append({"command": safe_command(h["command"]), "source": source})

    for path, data in user_settings():
        collect(data, rel(HOME, path))
    for pid, _, _, d in plugins:
        if d and (d / "hooks/hooks.json").is_file():
            collect(_json(d / "hooks/hooks.json"), f"plugin:{pid}")
    return out


def user_runtime(root: Path):
    plugins = enabled_plugins()
    agents = custom_agents(root, plugins)
    hooks = session_start_hooks(plugins)
    servers = mcp_servers(plugins)
    return {
        "plugins": [{"id": pid, "installed": bool(d), "path": str(d) if d else None} for pid, _, _, d in plugins],
        "agents": agents,
        "agents_est_tokens": sum(a["est_tokens"] for a in agents),
        "mcp_servers": servers,
        "session_start_hooks": hooks,
        "notes": [
            f"{len(plugins)} enabled plugin(s), {len(agents)} custom agent(s), {len(servers)} MCP server(s) and "
            f"{len(hooks)} SessionStart hook(s) also consume always-on context.",
            "Plugin skills, MCP tool schemas and SessionStart hook output are NOT counted in est_tokens: "
            "their size is only known at runtime. Read the total from /context in a fresh session.",
            "Hooks are listed, never executed. MCP entries are names only, with no env, header, URL or token.",
        ],
    }


def on_demand(root: Path, cfg: dict):
    droot = docs_root(root, cfg)
    files = [item(root, p, "doc") for p in iter_md(droot)]
    vault = cfg.get("vault") or {}
    vfiles = []
    if vault.get("enabled") and vault.get("path"):
        vp = Path(str(vault["path"]).replace("~", str(HOME), 1)).resolve()
        if vp != droot and not str(droot).startswith(str(vp)):
            vfiles = [item(root, p, "vault-note") for p in iter_md(vp)]
        elif vp != droot:
            vfiles = [item(root, p, "vault-note") for p in iter_md(vp) if not str(p.resolve()).startswith(str(droot))]
    return files, vfiles


def build(root: Path, include_user: bool):
    cfg = load_config(root)
    agents = enabled_agents(root, cfg)
    resolution = instruction_resolution(root, include_user, agents)
    report = {"project": str(root), "agents": {}, "include_user": include_user,
              "instruction_resolution": resolution}
    for a in agents:
        if a == "claude-code":
            al, co, hid, notes = claude_layers(root, include_user, resolution)
        elif a == "codex":
            al, co, hid, notes = codex_layers(root, include_user, cfg)
        elif a == "cursor":
            al, co, hid, notes = cursor_layers(root, include_user)
        else:
            al, co, hid, notes = antigravity_layers(root, include_user)
        report["agents"][a] = {
            "always_on": al, "conditional": co, "manual_only": hid, "notes": notes,
            "always_on_est_tokens": sum(x["est_tokens"] for x in al),
            "conditional_est_tokens": sum(x["est_tokens"] for x in co),
        }
    if include_user:
        report["user_runtime"] = user_runtime(root)
    report["always_on_floor"] = True
    report["git_environment"] = git_environment()
    report["measurement_note"] = (
        "est_tokens counts files only and is a LOWER BOUND on always-on context. Plugins, MCP servers, "
        "custom agents and SessionStart hook output are not measurable from disk. The authoritative "
        "number is /context in a fresh session.")
    docs, vault = on_demand(root, cfg)
    report["on_demand"] = {"docs_count": len(docs), "docs_est_tokens": sum(x["est_tokens"] for x in docs),
                           "vault_count": len(vault), "vault_est_tokens": sum(x["est_tokens"] for x in vault),
                           "largest_docs": sorted(docs + vault, key=lambda x: -x["est_tokens"])[:10]}
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=".")
    ap.add_argument("--include-user", action="store_true", help="also read ~/.claude, ~/.codex, ~/.gemini")
    ap.add_argument("--out")
    a = ap.parse_args()
    root = find_project_root(Path(a.project))
    report = build(root, a.include_user)
    # The resolution goes to stderr as well: it is the one answer nobody can deduce from
    # the repository, and it would otherwise be buried in the JSON nobody reads by eye.
    res = report["instruction_resolution"]
    for agent, text in res["effective"].items():
        print(f"{agent} reads: {text}", file=sys.stderr)
    print(f"Project instructions: {res['instruction_files']} (from {res['instruction_files_source']})",
          file=sys.stderr)
    print(dump_json(report, Path(a.out) if a.out else None))


if __name__ == "__main__":
    main()
