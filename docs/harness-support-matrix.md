# Harness Support Matrix

> WS0 deliverable of `docs/plans/2026-09-21-multi-harness-migration.md`. Every **tested** row
> was verified on this machine on 2026-09-21 with the version named; **docs** rows come from
> the vendor documentation fetched the same day and are not yet verified by a run. Update a row
> only with a run you can cite.

## Summary

| Harness | Version | Basis | Instructions | Skills | Agents | Hooks | MCP | Install |
|---|---|---|---|---|---|---|---|---|
| Claude Code | 2.1.278 | tested (daily) | `CLAUDE.md`, `AGENTS.md` (v2.1.277+, see modes) | `.claude/skills/` + plugin `skills` only | `.claude/agents/*.md` | full | `.mcp.json` | `.claude-plugin/` marketplace |
| Codex CLI | 0.153.4 | **tested** | `AGENTS.md` (project) + `~/.codex/AGENTS.md` (global) | plugin `"skills": "./.claude/skills"` ✅, `.agents/skills/` (project + `~/.agents/skills`) | `.codex/agents/*.toml` only | plugin `hooks/hooks.json` in Claude format ✅ — see caveats | ❌ plugin `.mcp.json` registered but `${CLAUDE_PLUGIN_ROOT}` not expanded | reads `.claude-plugin/marketplace.json` + `plugin.json` directly |
| OpenCode | 1.18.20 | **tested** | `AGENTS.md`, `~/.config/opencode/AGENTS.md` | `.claude/skills/` ✅, `.agents/skills/` ✅, `.opencode/skills/` | `.opencode/agents/*.md` only — `.claude/agents/` **not** read ✅ | none native; JS plugin API can host a shim | `opencode.json` `mcp` block | `opencode plugin <module>` |
| Cursor | — | docs | `AGENTS.md`, `.cursor/rules/*.mdc` | `.agents/skills/`, `.cursor/skills/`, legacy `.claude/skills/` | `.claude/agents/*.md` read directly | `.cursor/hooks.json` v1, camelCase events, own payload/output | `.cursor/mcp.json` | no plugin system |
| Gemini CLI | — | docs | `GEMINI.md` (`contextFileName` configurable) | `.gemini/skills/`, extension `skills/` | extension `agents/*.md` | `settings.json`/extension `hooks/hooks.json`, `BeforeTool`/`AfterTool`/… names | `settings.json` `mcpServers` | `gemini extensions install` |
| GitHub Copilot | — | docs | `.github/copilot-instructions.md`, `AGENTS.md` | unverified | — | none | — | — |

## Claude Code — `AGENTS.md` modes (docs, v2.1.277+)

| Repo has | Default (`claude-md-or-agents-md`) reads |
|---|---|
| `AGENTS.md`, no `CLAUDE.md`/`CLAUDE.local.md` in cwd or above | `AGENTS.md` |
| `AGENTS.md` **and** a `CLAUDE.md`/`CLAUDE.local.md` | `CLAUDE.md` only — `AGENTS.md` ignored |
| `CLAUDE.md` that imports `@AGENTS.md` | both, via the import |

Other modes: `claude-md-and-agents-md`, `claude-md`, `managed-only` — set under
`pluginConfigs."agents-md@builtin".options.instructionFiles` in user/managed settings only.
`.claude/rules/` load in every mode except `managed-only`. Bedrock/Vertex/Foundry and
telemetry-off sessions cannot read `AGENTS.md` directly — the import is the portable form.
Not read: `AGENTS.local.md`, anything under `.agents/`.

## Codex CLI 0.153.4 — tested detail

**Plugin.** `[marketplaces.<name>] source_type = "local"|"git"` pointing at a repo with
`.claude-plugin/marketplace.json`; `codex plugin add mtk@moberghr` clones the repo into
`~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` (a full git clone, `.git` included)
and reads `.claude-plugin/plugin.json` as-is. No Codex-specific manifest is needed; a root
`plugin.json`/`mcp.json` (agent-plugins schema) was **ignored** when present alongside.

**Skills.** `"skills": "./.claude/skills"` loads every skill, namespaced `mtk:<name>` in the
model's skill list. A skill carrying non-spec top-level keys (`type`, `effort`, `context`,
`user-invocable`, `trigger`, `required-toolsets`) **loaded** — lenient parsing. A `SKILL.md`
with no frontmatter logs `failed to load skill … missing YAML frontmatter` and is skipped.
`~/.agents/skills/` and project `.agents/skills/` are also scanned.

**Hooks.** Requires `[features] hooks = true`. Events run: `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `Stop` (also documented: `SessionEnd`, `PermissionRequest`,
`PreCompact`, `PostCompact`, `SubagentStart/Stop`, `Interrupt`). `${CLAUDE_PLUGIN_ROOT}` in
`hooks/hooks.json` commands **is expanded**. Matcher tool names are Claude's:

| Codex action | Hooks that fired | ⇒ `tool_name` matches |
|---|---|---|
| shell (`exec`) | security-gate, interactive-guard, rule-trigger (3) | `Bash` |
| `apply_patch` | scope-guard, rule-trigger (2) | `Edit`\|`Write` |
| file read | none — Codex reads with `cat` via shell | no `Read`/`Grep`/`Glob` tools exist |

Consequence: `hooks/read-guard.sh` (secret-file read block) **never fires** under Codex, and
there is no `permissions.deny` equivalent — a secret read via `cat .env` is uncaught until the
security gate learns to classify secret-pattern paths in shell commands.

Output protocol: exit 2 + stderr → the model sees
`Command blocked by PreToolUse hook: BLOCKED: Force push to main/master is not allowed.`
(verified with `security-gate.sh`). `hookSpecificOutput.additionalContext` from `session-start`
lands in the transcript as a developer message (`content_item_kinds: ["hooks.additional…"]`).
`[mtk-hook:<name>] exit N` diagnostics on stderr are surfaced too.

Trust: Codex pins a `trusted_hash` per hook in `~/.codex/config.toml`
(`[hooks.state."mtk@moberghr:hooks/hooks.json:<event>:<group>:<index>"]`) at interactive
install time. Hooks added or changed by a later plugin update are reported as
`hook: <Event> Failed` and do not run until re-trusted — on this machine `format-on-edit.sh`
(PostToolUse) and one Stop hook, both added after the 7.31 trust snapshot. A project-level
`.codex/hooks.json` never ran under `codex exec` (untrusted; no trust prompt non-interactively).
The hash input format was not recovered (command string, hook JSON, script contents and file
hash all mismatch).

**MCP.** The plugin's `.mcp.json` is registered (`codex mcp list` shows `mtk-context`) but
`${CLAUDE_PLUGIN_ROOT}` in `args` stays literal, so the server never starts —
`mtk_active_stack` reports unavailable. Root `mcp.json` with `${PLUGIN_ROOT}` was not
registered at all.

**Agents.** `~/.codex/agents/*.toml` and `.codex/agents/*.toml` with `name`, `description`,
`developer_instructions` (+ `model`, `model_reasoning_effort`, `sandbox_mode`). Markdown
`.claude/agents/` is not read. The 2026-08-13 conversion found on this machine replaced
`.claude/` with `.Codex/` and `CLAUDE.md` with `AGENTS.md` by string substitution — the
resulting reviewer cites paths that do not exist. A generator must rewrite paths, not case.

**Other.** Codex's own approval reviewer rejects `rm -rf`-style commands before any hook.
`codex exec` appends piped stdin to the prompt (`Reading additional input from stdin…`) —
pass `</dev/null` or `-` with the prompt on stdin.

## OpenCode 1.18.20 — tested detail

- `opencode run` in a project with `.claude/skills/handoff` and `.agents/skills/prior-work-check`
  listed **both** skills (plus `~/.claude/skills`, `~/.agents/skills`, `~/.config/opencode/skill`
  globals). Docs: only `name`, `description`, `license`, `compatibility`, `metadata` are read;
  unknown keys ignored.
- `opencode agent list` showed `.opencode/agents/oc-probe.md` and **not**
  `.claude/agents/test-reviewer.md`. Agent frontmatter: `description`, `mode`
  (`primary|subagent|all`), `model`, `permission`, `temperature`; subagents invoked by `@name`.
- No hook system. Plugin API (`@opencode-ai/plugin` 1.4.3): `tool.execute.before({tool, sessionID, callID}, {args})`,
  `tool.execute.after(…, {title, output, metadata})`, `permission.ask(Permission, {status})`,
  `command.execute.before`, `chat.message`, `shell.env`, `experimental.session.compacting`,
  `event`. A ~100-line shim can build a Claude-shaped payload, run the MTK hook scripts, and map
  exit 2 → `status: "deny"` / `additionalContext` → appended output. Candidate for Tier B.
- MCP: `~/.config/opencode/opencode.json` `mcp.<name> = {type: "local", command: [...]}`.

## Not tested here

Cursor, Gemini CLI and Copilot are not installed on this machine. Their rows are documentation
only; the WS0 items that concern them (Cursor `.claude/agents` with `model: fable`, Gemini
`@./AGENTS.md` import, Copilot skill discovery) stay open.
