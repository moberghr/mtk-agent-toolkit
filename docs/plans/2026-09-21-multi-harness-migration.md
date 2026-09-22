# MTK Multi-Harness Migration Plan — 2026-09-21

**Trigger.** Claude Code v2.1.277 (2026-09-18) reads `AGENTS.md` natively. Default mode is
`claude-md-or-agents-md`: when a `CLAUDE.md`/`.claude/CLAUDE.md`/`CLAUDE.local.md` exists
in cwd or above, `AGENTS.md` is **ignored**; `claude-md-and-agents-md` loads both; a
`CLAUDE.md` that `@AGENTS.md`-imports gets it via the import. `.claude/rules/` keep loading
in every mode except `managed-only`. Bedrock/Vertex/Foundry and telemetry-off sessions
cannot read `AGENTS.md` directly and need the import. Not read: `AGENTS.local.md`,
anything under `.agents/`.

**Goal.** One MTK source tree that installs and *enforces* on Claude Code, Codex CLI,
Cursor and Gemini CLI, and degrades to skills + instructions on OpenCode / Copilot, with no
per-harness fork of skills, agents, or hook logic. Every harness-specific file is generated
from the canonical source and checked in sync by `validate-toolkit.sh`, the same way
`triggers.index` and `references.index` are today.

**Method.** Each workstream names the files it touches, the proof that it landed, and what
must not change. Facts marked *(verified)* come from the harness docs fetched on 2026-09-21;
facts marked *(verify)* are assumptions the Phase 0 spike must confirm before the dependent
workstream starts.

---

## Baseline — what is already portable, what is not

### Already portable (keep, do not rework)

| Layer | State |
|---|---|
| `SKILL.md` format | Agent Skills open spec. 33/45 skills already carry `license` + `compatibility`. Read natively by Codex (`.agents/skills`), Cursor (`.agents/skills`, `.cursor/skills`, legacy `.claude/skills`/`.codex/skills`), Gemini (`.gemini/skills`, extension `skills/`), OpenCode (`.opencode/skills`, `.claude/skills`, `.agents/skills`). Claude Code reads **only** `.claude/skills/` + plugin `skills/` *(verified)*. |
| Dynamic injection `` !`cmd` `` | 0 real uses (only `writing-skills` mentions it). Good — Cursor/Codex/Gemini do not execute it. |
| Agents (`.claude/agents/*.md`) | Cursor reads `.claude/agents/` markdown directly (`name`, `description`, `model`, `readonly`, `is_background`) *(verified)*. Gemini extensions bundle `agents/*.md`. Codex needs TOML (see WS5). |
| Hook I/O | `hooks/lib/hook-io.sh` already parses flat (`{"command":…}`) and nested (`tool_input`) payloads; `session-start` already branches on `CURSOR_PLUGIN_ROOT` / `COPILOT_CLI` / `GEMINI_EXTENSION_ROOT`. Exit code `2` = block on Claude, Codex, Cursor, Gemini *(verified)*. |
| Codex hook protocol | Near-identical to Claude Code: events `SessionStart/End, PreToolUse, PostToolUse, PermissionRequest, PreCompact, PostCompact, UserPromptSubmit, SubagentStart/Stop, Stop, Interrupt`; stdin `session_id, cwd, hook_event_name, tool_name, tool_input`; stdout `hookSpecificOutput.additionalContext`, `decision: block`, `permissionDecision`; plugin-bundled `hooks/hooks.json`; env `PLUGIN_ROOT`, `PLUGIN_DATA` *(verified)*. Requires `[features] hooks = true` in `config.toml` *(verified)*. |
| Gemini hook protocol | Same stdin/stdout shape (`tool_name`, `tool_input`, `decision`, `hookSpecificOutput.additionalContext`, exit 2) but **different event names**: `BeforeTool, AfterTool, BeforeAgent, AfterAgent, BeforeModel, AfterModel, BeforeToolSelection, SessionStart, SessionEnd, PreCompress, Notification`; configured in `settings.json` `hooks` or extension `hooks/hooks.json` *(verified)*. |
| Cursor hook protocol | Different everywhere: camelCase events (`preToolUse, postToolUse, beforeShellExecution, afterFileEdit, beforeReadFile, beforeSubmitPrompt, preCompact, stop, sessionStart, subagentStop …`), flat payload (`command`, `cwd`), stdout `permission: allow|deny|ask`, `additional_context`, `followup_message`, `failClosed`; `.cursor/hooks.json` with `"version": 1`; env `CURSOR_PROJECT_DIR` **and** `CLAUDE_PROJECT_DIR` *(verified)*. |
| MCP server | stdio, read-only — any MCP client. Registration file differs per harness (WS6). |
| Cross-tool config generators | `scripts/generate-agents-md.sh` (budget-capped summary), `scripts/generate-tool-configs.sh` (Cursor `.mdc`, Copilot, Windsurf, Gemini, Cline), bootstrap STEP 2.7 ingestion of foreign configs, `AGENTS.md` in `manifest.protected`. |

### Claude-Code-specific surface (the migration)

| Surface | Count / location | Why it breaks elsewhere |
|---|---|---|
| Layout under `.claude/` | 615 `.claude/` path refs in skills; `.claude/rules/`, `.claude/settings.json`, `.claude/tech-stack` | Only Claude auto-loads `.claude/rules/`; others need AGENTS.md pointers or `.cursor/rules` mirrors |
| Env vars | `CLAUDE_PLUGIN_ROOT` ×105, `CLAUDE_PROJECT_DIR` ×36, `CLAUDE_CODE_SESSION_ID` ×7, `CLAUDE_CONFIG_DIR` ×4 (hooks, scripts, skills) | Codex sets `PLUGIN_ROOT`; Cursor `CURSOR_PROJECT_DIR`; Gemini `${extensionPath}` |
| Tool names in prose | `AskUserQuestion` in 14 skills; `Agent` dispatch in `subagent-implementation` (×8), `implement`, `batch-fix`, `code-review-and-quality` | Other harnesses have different or no equivalents |
| Hook matchers by Claude tool name | `Bash`, `Edit\|Write`, `Read\|Grep\|Glob` in `hooks/hooks.json` + `.claude/settings.json` | Gemini tools are `run_shell_command`, `write_file`, `replace`, `read_file`…; Cursor uses per-action events; Codex tool names *(verify)* |
| Claude-only hook events | `SessionStart(matcher: compact)`, `PreCompact`, `Stop`, `SubagentStop` | Gemini has `PreCompress`/`AfterAgent`, no post-compact re-arm; Cursor `stop` continues via `followup_message`, not `decision: block` |
| Frontmatter keys Claude honours top-level | `allowed-tools`, `context: fork`, `effort`, `user-invocable`, `argument-hint` | Must stay top-level for Claude; harmless elsewhere *(verify lenient YAML on Codex/Gemini)* |
| MTK-only frontmatter keys | `type` ×45, `trigger`/`skip_when` ×30, `triggers` ×4, `required-toolsets` ×3 | Not in the spec; belong under `metadata:` for `skills-ref validate` |
| Permissions `allow`/`deny` | `.claude/settings.json` | Gemini `excludeTools`; Codex sandbox/policies; Cursor has none |
| Session/plugin state paths | `~/.claude/plugins` cache search in `mtk-file-resolution.md`; 9 `~/.claude` refs; native memory dir in `promote-lesson` | Different homes per harness |
| Naming & positioning | `claude-md-audit`, `claude-md-capture`, `.claudeignore`, README "Do I need Claude Code? Yes" | Names bake in one harness |
| Claude-only features | `Workflow` (`templates/workflows/*.workflow.js`), `Artifact` publishing, `EnterPlanMode`, `ReportFindings` | Already opt-out or optional; need documented degradation |

---

## Support tiers (D1 — agreed)

| Tier | Harness | What works |
|---|---|---|
| **A — full enforcement** | Claude Code, Codex CLI | Skills, agents, all hooks (PreToolUse deny, Stop gates, session recovery), MCP, plugin install |
| **B — enforcement with adapter** | Cursor, Gemini CLI | Skills, agents, hooks through the protocol adapter (WS3); some events degrade (no post-compact re-arm on Gemini; Cursor Stop via `followup_message`) |
| **C — instructions + skills** | OpenCode (→ B once WS3b lands), GitHub Copilot | AGENTS.md, skills, agents where read; **no hook enforcement** — rules are advisory, `pre-commit-review` runs via the git pre-commit hook only |
| **D — instructions only** | Windsurf, Cline, anything else | Generated pointer file → AGENTS.md |

The tier a repo gets is recorded at setup (WS7) and reported by `mtk-doctor`.

---

## WS0 — Spike: verify the *(verify)* facts (S, blocks WS3/WS4/WS6)

One throwaway repo per Tier A/B harness, MTK installed by hand. Confirm and write down in
`docs/harness-support-matrix.md`:

1. Codex `tool_name` values for shell / file-write / file-read tool calls, and whether
   `PreToolUse` fires for `apply_patch`.
2. Codex portable `plugin.json`: can `"skills"` point at `./.claude/skills` (Claude's
   `.claude-plugin/plugin.json` already does) or must the path be `./skills/`?
3. Lenient frontmatter parsing on Codex, Cursor, Gemini, OpenCode: do unknown top-level keys
   (`effort`, `context`, `type`) load or reject the skill? Run `skills-ref validate` on the
   tree as the spec baseline.
4. Gemini: does `GEMINI.md` `@./AGENTS.md` import work, or set `contextFileName` to
   `AGENTS.md` in the extension manifest?
5. Cursor `.claude/agents/` read: does an unknown `model: fable` alias fail or fall back to
   `inherit`? Does `tools:` (Claude key) get ignored safely?
6. Copilot CLI / coding agent: which of `AGENTS.md`, `.github/copilot-instructions.md`,
   `.claude/skills` are read today.

**Proof.** Matrix committed; each row cites the harness version tested.

### WS0 results — Codex CLI 0.153.4 and OpenCode 1.18.20 (2026-09-21, this machine)

Full detail in `docs/harness-support-matrix.md`. What changes in the plan:

- **#1 Codex `tool_name`** — Claude's names. Shell fires the `Bash` hooks (3), `apply_patch`
  fires the `Edit|Write` hooks (2). Codex has no Read/Grep/Glob tools (it `cat`s via shell), so
  `read-guard.sh` never fires there → WS3 adds a shell-side secret-path classifier to
  `security-gate.sh` (portable replacement for both `read-guard` and `permissions.deny Read(.env)`).
  `security-gate.sh` **blocked** a forced push to `main` under Codex end to end.
- **#2 `"skills": "./.claude/skills"`** — loads (namespaced `mtk:<skill>`). Root `plugin.json` /
  `mcp.json` (agent-plugins schema) are ignored when `.claude-plugin/` exists → WS6 ships **no**
  Codex manifest (confirms `af1ebb3`).
- **#3 Lenient frontmatter** — confirmed on Codex (skill with `type`/`effort`/`context`/
  `user-invocable`/`trigger`/`required-toolsets` loaded) and OpenCode (docs: unknown keys
  ignored). D4 stands on spec-cleanliness, not on breakage.
- **MCP under Codex is broken** — `.mcp.json` is registered but `${CLAUDE_PLUGIN_ROOT}` stays
  literal. WS6 gains a fix task: a launcher that resolves its own location
  (`scripts/mcp-launch.sh` invoked by an absolute path the SessionStart hook can compute), or a
  documented `codex mcp add mtk-context node <cache>/dist/mtk-mcp-server.cjs` step in
  `mtk-doctor --fix`.
- **Codex pins hook trust per hook at interactive install.** Hooks added after that show
  `hook: <Event> Failed` and do not run (`format-on-edit.sh` and one Stop hook on this machine).
  WS7 doctor: compare `hooks.state."mtk@…"` entry count in `~/.codex/config.toml` with
  `hooks/hooks.json` and WARN "re-trust in Codex TUI". Release notes must say so on every
  hooks.json change. Project `.codex/hooks.json` is not loaded non-interactively → never generate it.
- **OpenCode** reads `.claude/skills` and `.agents/skills` natively but not `.claude/agents`
  → WS5 adds an `.opencode/agents/<name>.md` generator (`description`, `mode: subagent`,
  `permission` read-only). Its plugin API (`tool.execute.before/after`, `permission.ask`,
  `experimental.session.compacting`) can host a shim that runs MTK hook scripts with a
  Claude-shaped payload → new **WS3b** (`mtk-opencode` plugin, ~100 lines), promoting OpenCode
  from Tier C to Tier B when it lands.
- **Local leftovers.** This checkout has gitignored `.agents/skills/` (46 stale copies from
  2026-08-13) and `.codex/` (TOML agents with `.claude/`→`.Codex/` string-mangled paths, a
  `hooks.json` Codex never loads). They are not consumed by anything; delete when convenient.
- **Not tested here:** Cursor, Gemini, Copilot (not installed) — their WS0 items stay open.

---

## WS1 — Instruction layer: AGENTS.md becomes canonical (M, independent)

**Why first.** Zero plumbing risk, immediate value on every harness, and the Claude Code
change makes it free.

**Toolkit repo.**
- Move the constitution (`CLAUDE.md` Skill Routing, Build & Test, Project Profile, Critical
  Rules, Standards Reference) into `AGENTS.md`. Fold the current hand-curated routing guide
  (Mermaid tree, two-stage review, tech-stack loading) into the same file under its own H2s.
  Keep the whole thing inside the instruction budget (`bootstrap-supporting-files.md` §Cross-Agent:
  60–120 lines target, 140 ceiling — raise to match today's 109 + essentials, or split the
  routing tree into `.claude/references/routing-guide.md` and point at it).
- `CLAUDE.md` becomes a shim: `@AGENTS.md` + a `## Claude Code only` section (hook env knobs
  table, plugin-manager update note, `.claude/rules/` pointer). This is the recommended shape
  because (a) Bedrock/Vertex sessions cannot read `AGENTS.md` directly, (b) a shim keeps the
  default `claude-md-or-agents-md` mode working with no `/config` change on every engineer's
  machine, (c) `claudeMdExcludes` and import dedup already handle the double-load case.
- `.claude/rules/*.md` stay (Claude auto-loads them alongside either file). `AGENTS.md`
  carries the `INDEX.md` table so non-Claude harnesses know the rules exist and where.
- `.mtkignore`: `AGENTS.md`/`CLAUDE.md`/`GEMINI.md` already excluded — add generated pointer
  files (WS7).

**Target repos (bootstrap output).**
- `generate-agents-md.sh` stops being a *summary* of references and becomes the *primary*
  constitution generator (what `setup-bootstrap` STEP 3 writes to `CLAUDE.md` today).
  `CLAUDE.md` in a target repo becomes the same shim. `CLAUDE.local.md` guidance: note in
  the STEP 5 report that a `CLAUDE.local.md` does **not** break the shim (the shim imports
  `AGENTS.md`, so the fallback rule is irrelevant) — this is the second reason for the shim
  over "no CLAUDE.md at all".
- `scripts/constitution-digest.sh` reads `AGENTS.md` first, `CLAUDE.md` second (the
  digest-reads-plugin-CLAUDE.md bug from the 2026-09 field run is the same class).
- Rename `claude-md-audit` → `instructions-audit`, `claude-md-capture` → `instructions-capture`
  (D6 agreed); both operate on `AGENTS.md` with `CLAUDE.md`/`GEMINI.md` shims as secondary
  targets. Router keywords keep "claude.md" as synonyms so muscle memory works.
- `generate-tool-configs.sh`: Copilot/Windsurf/Cline outputs shrink to a marker + "read
  `AGENTS.md`" pointer + Critical Rules verbatim (the one section worth duplicating for
  tools with no import). Cursor `.mdc` rules stay glob-scoped (they add path scoping
  `AGENTS.md` cannot express). `GEMINI.md` becomes `@./AGENTS.md` import if WS0 #4 confirms.

**Proof.** In this repo: `claude --print "what are the critical rules"` answers identically
from (a) current tree, (b) migrated tree with default mode, (c) migrated tree with
`claude-md-and-agents-md`. `codex` in the same tree lists the same rules. `tests/test-generate-agents-md.sh` extended for the constitution mode. `validate-toolkit.sh` gains: `CLAUDE.md` must contain `@AGENTS.md`; `AGENTS.md` line budget.

**Must not change.** `manifest.protected` semantics (both files stay protected); the
never-overwrite marker guard in both generators.

---

## WS2 — Path & environment abstraction (M, prerequisite for WS3/WS6/WS7)

- `hooks/lib/hook-io.sh`: add `mtk_harness()` → `claude|codex|cursor|gemini|copilot|opencode|unknown`,
  detected from env (`CLAUDE_PLUGIN_ROOT`/`CLAUDE_CODE_SESSION_ID`, `PLUGIN_ROOT`+`CODEX_*`,
  `CURSOR_PROJECT_DIR`/`CURSOR_VERSION`, `GEMINI_EXTENSION_ROOT`, `COPILOT_CLI`) then from
  payload (`cursor_version`, `hook_event_name` casing). Memoised per process like
  `mtk_repo_root`.
- `mtk_plugin_root()` → first of `MTK_HELPER_ROOT`, `CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`,
  `CURSOR_PLUGIN_ROOT`, `GEMINI_EXTENSION_ROOT`, script-relative `dirname` walk.
  `mtk_repo_root()` adds `CURSOR_PROJECT_DIR` and payload `cwd` before the `git rev-parse`
  fallback. `mtk_session_id()` from `CLAUDE_CODE_SESSION_ID`, payload `session_id`,
  `conversation_id`.
- Replace the 105 `CLAUDE_PLUGIN_ROOT` / 36 `CLAUDE_PROJECT_DIR` / 7 session-id references in
  `hooks/` and `scripts/` with the helpers. `hooks/hooks.json` command paths keep
  `${CLAUDE_PLUGIN_ROOT}` (Claude substitutes it); the generated Codex/Gemini copies use
  `${PLUGIN_ROOT}` / `${extensionPath}` (WS3).
- `.claude/references/mtk-file-resolution.md`: resolution order gains the other plugin
  caches (`~/.codex/plugins`, `~/.gemini/extensions`, `~/.agents/plugins`) in step 4, and
  the router's `MTK_ROOT=` line is the only thing skills see — no skill edits needed beyond
  the 9 `## MTK File Resolution` blocks already pointing at the reference.
- Session-scoped state: anything under `~/.claude/` that is MTK's own (queue, analytics
  scratch, lock files) moves to `${XDG_STATE_HOME:-$HOME/.local/state}/mtk/<repo-hash>/`.
  Native memory dir in `promote-lesson` becomes a per-harness lookup (Claude
  `~/.claude/projects/<cwd>/memory/`; others: skip with a one-line note).

**Proof.** `grep -rE 'CLAUDE_(PLUGIN_ROOT|PROJECT_DIR|CODE_SESSION_ID)' hooks scripts` returns
only `hook-io.sh` and `hooks.json`. Every hook test in `tests/hooks/` runs once per harness
env preset (a `for h in claude codex cursor gemini` wrapper) and passes.

**Must not change.** `mtk_repo_relative_path` inode comparison (S1.17); the bounded stdin
read; fail-closed behaviour of `security-gate.sh`.

---

## WS3 — Hooks: one logic, four protocols (L, depends on WS0 #1, WS2)

**Input adapter** (`hook-io.sh`): `mtk_extract_command` / `mtk_extract_file_path` learn Cursor's
flat `command`/`file_path`; `mtk_extract_tool_name` returns a **capability class**
(`shell | file-write | file-read | search | other`) via a per-harness table in
`hooks/lib/harness-tools.sh` (Claude `Bash/Edit/Write/Read/Grep/Glob`, Gemini
`run_shell_command/write_file|replace/read_file/grep_search|glob`, Codex from WS0, Cursor
from event name). Hooks branch on the class, never on the raw name.

**Output adapter**: `mtk_deny`, `mtk_emit_additional_context`, `mtk_emit_stop_block`,
`mtk_emit_system_message` emit per `mtk_harness()`: Claude/Codex/Gemini share
`hookSpecificOutput`/`decision`; Cursor gets `permission: deny` + `user_message`/`agent_message`,
`additional_context`, and `followup_message` for stop. Exit 2 stays the universal block.

**Event mapping & generated configs**: a harness-neutral `hooks/hooks.source.json` (events
named by MTK: `session-start`, `pre-tool`, `post-tool`, `pre-compact`, `post-compact`,
`prompt-submit`, `stop`, `subagent-stop`, matchers by capability class) and
`scripts/generate-hook-configs.sh` emitting:

| Target | Output |
|---|---|
| Claude Code | `hooks/hooks.json` (today's file, now generated) + `.claude/settings.json` hooks block |
| Codex | `hooks/hooks.json` for the plugin (same shape, `${PLUGIN_ROOT}`), `.codex/hooks.json` for project installs |
| Gemini | extension `hooks/hooks.json` with `BeforeTool/AfterTool/AfterAgent/PreCompress/SessionStart` and regex matchers on Gemini tool names; `.gemini/settings.json` fragment for project installs |
| Cursor | `.cursor/hooks.json` `version: 1`, camelCase events (`beforeShellExecution` for the security gate, `afterFileEdit` for format-on-edit, `beforeSubmitPrompt` for `userprompt-dispatch`, `stop` for the Stop family, `preCompact`) |

Degradations, written into the matrix and reported by doctor: Gemini has no post-compact
event → `rule-trigger.sh --rearm` and `post-compact.sh` do not run; Cursor Stop hooks cannot
`decision: block`, they return `followup_message` (the verify-completion nag becomes a
follow-up prompt, not a hard stop); Copilot/OpenCode: no hooks at all — the git pre-commit
hook (`hooks/git-hooks/pre-commit`) is the only enforcement and bootstrap says so.

**Codex feature flag**: install docs and `mtk-doctor` check `[features] hooks = true`.

**Proof.** `tests/hooks/fixtures/<harness>/<event>.json` golden payloads (recorded in the WS0
spike); every `hooks/*.sh` runs against every fixture it is wired to; assertions on exit
code and stdout JSON per harness. `validate-toolkit.sh`: all four generated configs in sync
with `hooks.source.json` (same pattern as `triggers.index`).

**Must not change.** Which checks run and their thresholds (`security-gate`, `scope-guard`,
`interactive-guard`, `collateral-guard`, `read-guard`); the tier-2 kill switch
`MTK_HOOKS_TIER2`; hook latency budget.

---

## WS4 — Skills: spec-clean frontmatter and harness-neutral prose (M, depends on WS0 #3)

- **Frontmatter.** Keep the Claude-honoured keys top-level (`allowed-tools`, `context`,
  `effort`, `user-invocable`, `argument-hint`, `license`, `compatibility`). Move MTK-only keys
  under `metadata:` with an `mtk-` prefix: `type` → `metadata.mtk-type`, `trigger`/`skip_when`
  → `metadata.mtk-trigger`/`mtk-skip-when`, `triggers` → `metadata.mtk-triggers`,
  `required-toolsets`/`forbidden-toolsets` → `metadata.mtk-required-toolsets`/…. One-shot
  migration script (`scripts/migrate-skill-frontmatter.py`, sibling of
  `migrate-reference-frontmatter.py`); update `validate-toolkit.sh`,
  `build-triggers-index.sh`, `resolve-toolsets.sh`, the `/mtk` router's toolset expansion,
  `writing-skills`, `docs/skill-anatomy.md`, S2.1/S2.12/S2.19/S2.22/S2.25. `metadata` values
  must be strings per spec — `triggers` becomes a comma-joined string.
  *(D4 agreed. WS0 #3 still runs — it tells us whether the pre-migration tree keeps
  loading on each harness while the train is in flight.)*
- **Prose.** Replace harness tool names with capability phrasing plus a per-harness gloss,
  once, in a new `.claude/references/harness-primitives.md` (ask-the-engineer,
  dispatch-a-subagent, isolated-context, plan-mode, publish-artifact) and point the 14
  `AskUserQuestion` sites and the `Agent`-dispatch sites at it: "ask one question (see
  harness-primitives → *ask*)". `MTK_SUBAGENT_DISPATCH` auto-resolves to `0` on harnesses
  without a subagent primitive (Copilot; OpenCode until verified) so `implement` takes the
  inline-MAX path without the engineer setting anything.
- **Rules.** S2.18 currently *recommends* `` !`command` `` injection — invert it: forbidden
  in shipped skills (Cursor/Codex/Gemini/claude.ai-synced skills render it literally);
  validator fails on `` !` `` outside fenced examples. New S2.27: tool names appear only in
  `harness-primitives.md` and `allowed-tools`.
- **Slash invocation.** Skill names are the portable handle (`/mtk`, `/mtk-setup` on Claude
  and Cursor; `$mtk`/skill name on Codex). Router help text says so per harness.

**Proof.** `skills-ref validate .claude/skills/*` passes; `grep -lE 'AskUserQuestion|\bAgent\b tool' .claude/skills` returns only `harness-primitives.md` consumers' one-line pointers; description budget unchanged (6,803/7,000 chars).

---

## WS5 — Agents on every harness (S–M, independent of WS3)

- `.claude/agents/*.md` stays canonical. Add `readonly: true` (Cursor key, ignored by
  Claude) to all six reviewers — it is what `tools:` already says.
- `scripts/generate-agent-configs.sh` from the six markdown files:
  - Codex: `.codex/agents/<name>.toml` with `name`, `description`,
    `developer_instructions` (= body), `model_reasoning_effort` (= `effort`, mapped
    `max`→`high`), `sandbox_mode = "read-only"`.
  - Cursor: nothing if WS0 #5 shows `.claude/agents/` loads with `model: fable` → else
    `.cursor/agents/<name>.md` with `model: inherit`.
  - Gemini: extension `agents/<name>.md` (copy with Claude-only keys stripped).
  - OpenCode: `.opencode/agents/<name>.md` with `description`, `mode: subagent`, read-only
    `permission` (WS0: `.claude/agents/` is not read).
- Reviewer dispatch prose in `implement` Phase 4 / `code-review-and-quality` goes through
  `harness-primitives.md` → *dispatch*, naming the agent, not the tool.
- Validator: generated agent files in sync; `tools:` still mandatory and non-granting (S1.7).

**Proof.** Each Tier A/B harness lists the six reviewers and `compliance-reviewer` runs
read-only against a seeded defect in the spike repo.

---

## WS6 — Packaging: one version, four manifests (M, depends on WS2/WS3/WS5)

| Harness | Manifest | Notes |
|---|---|---|
| Claude Code | `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` | exists |
| Codex | **none** — Codex reads `.claude-plugin/marketplace.json` + `plugin.json` directly and ignores a root `plugin.json`/`mcp.json` beside them *(WS0 tested)* | Fix MCP: `${CLAUDE_PLUGIN_ROOT}` is not expanded in `.mcp.json` args → self-locating launcher or `mtk-doctor --fix` registering an absolute path. Re-trust note on every hooks.json change |
| Gemini | `gemini-extension.json` (`name`, `version`, `description`, `mcpServers` with `${extensionPath}`, `contextFileName`), dirs `skills/`, `hooks/hooks.json`, `agents/`, `commands/*.toml` *(verified)* | `skills/`/`agents/` are the generated copies from WS3/WS5 (D3: no symlinks) |
| Cursor | no plugin system (feature request only) | project-level install via bootstrap (WS7): `.cursor/hooks.json`, `.cursor/rules/`, `.agents/skills/` |
| OpenCode | `.opencode/plugins/mtk.js` shim (WS3b) + `opencode.json` `mcp` block | no marketplace; bootstrap writes the shim and agents into the target repo |

- `scripts/generate-manifests.sh` writes every manifest's `version` from `.claude/manifest.json`;
  C0.1/S1.4 extend to all of them; `validate-toolkit.sh` and the release workflow enforce.
- `dist/mtk-mcp-server.cjs` is gitignored and rebuilt by `session-start` — harnesses without
  a session hook (Copilot) or without Node in the plugin sandbox need it shipped: attach the
  bundle to the GitHub release and have `mtk-doctor --fix` fetch it *(D5 agreed)*.
- `docs/integrations/mtk-mcp.md` gains Codex (`mcp.json` / `config.toml [mcp_servers]`),
  Cursor (`.cursor/mcp.json`), Gemini (`settings.json mcpServers`) registration blocks.

**Proof.** `codex plugin marketplace add moberghr/moberg-plugins` → install → `/mtk-setup`
runs in the spike repo; `gemini extensions install <repo>` idem; `checksums.sha256` covers
the new manifests.

---

## WS7 — Setup, refresh and doctor become harness-aware (M, depends on WS1/WS3/WS5/WS6)

- `/mtk-setup` STEP 4 replaces the "Generate cross-agent configs?" question with a
  multi-select **"Which harnesses does the team use?"** (Claude Code / Codex / Cursor /
  Gemini / Copilot / OpenCode / other). Records the answer in `.claude/harnesses` (protected,
  one word per line — sibling of `.claude/tech-stack`). `--non-interactive` default: the
  harness the session is running on + AGENTS.md.
- Per selected harness, bootstrap writes the generated files (WS1 pointers, WS3 hook
  configs, WS5 agents, WS6 MCP registration, `.agents/skills/` copy for Cursor only, per D3,
  ignore files: `.claudeignore`, `.cursorignore`, `.geminiignore`) — every one carrying the
  `Auto-generated by MTK` marker and honouring the never-overwrite guard. "Never orphan an
  already-adopted tool" rule stays.
- `setup-refresh` / `--check`: the staleness plan gains one row per harness artifact
  (regenerate-and-diff, same as AGENTS.md today).
- `mtk-doctor`: new **HARNESS** section — detected harness, recorded tier, Claude Code
  ≥ 2.1.277 and `instructionFiles` mode (warn if `CLAUDE.md` lacks `@AGENTS.md`), Codex
  `features.hooks`, Cursor `hooks.json` `version`, generated configs in sync with source,
  `.agents/skills` drift if copied. `--json` carries it for CI.
- `repo-health` 12-asset scorecard: asset 13 = "instructions readable by every harness the
  team recorded".

**Proof.** Bootstrap in the spike repos with each single-harness selection produces only that
harness's files; `--check` exits 1 when a generated hook config is hand-edited;
`tests/test-mtk-doctor-*.sh` gains harness cases.

---

## WS8 — Docs, rules, positioning (S, last)

- README: "Works with Claude Code, Codex CLI, Cursor and Gemini CLI (enforcement); OpenCode
  and Copilot (skills + instructions)"; badge; Quick Start per harness; FAQ "Do I need
  Claude Code?" → "No — see the support matrix"; comparison table row updated.
- `docs/harness-support-matrix.md` (from WS0) linked from README, AGENTS.md, CHANGELOG.
- Rules: S1.18 (harness-specific files are generated, never hand-edited; source list), S2.27
  (tool names only in `harness-primitives.md`), S2.18 inverted, S3.18 (hook I/O only via
  `hook-io.sh` adapters; no raw `printf` of protocol JSON).
- `toolkit_architecture_snapshot` memory and `project_workflow` memory updated.
- CHANGELOG under `[Unreleased]` → release notes; this is a **major** bump (8.0.0) because
  the frontmatter migration (D4), the renames (D6) and the `CLAUDE.md`→shim change alter
  what target repos receive.

---

## Sequencing

```
WS0 spike ─┬─► WS3 hooks ──┐
           ├─► WS4 skills ─┼─► WS6 packaging ─► WS7 setup/doctor ─► WS8 docs
           └─► WS5 agents ─┘         ▲
WS1 instructions (independent) ──────┘
WS2 env/paths ─► WS3
```

Suggested release train: **7.36** = WS1 + WS2 (no behaviour change on Claude Code, value on
every AGENTS.md reader today); **7.37** = WS0 + WS3 (Codex Tier A lands — the cheapest
second harness because its protocol is Claude's); **7.38** = WS4 + WS5; **8.0.0** = WS6 +
WS7 + WS8 (Cursor/Gemini Tier B, new manifests, renames).

Each WS is one branch, one PR, dogfooded in a spike repo before merge — same discipline as
the field-run PRs (#102/#103, #105/#106).

---

## Decisions — resolved 2026-09-21

| # | Decision | Resolution |
|---|---|---|
| D1 | Support tiers | **A:** Claude Code, Codex CLI. **B:** Cursor, Gemini CLI. **C:** Copilot, OpenCode. **D:** everything else via AGENTS.md pointer |
| D2 | Instruction layer | `AGENTS.md` canonical; `CLAUDE.md` is a shim (`@AGENTS.md` + `## Claude Code only`) |
| D3 | Skills for non-Claude harnesses in target repos | Plugin-only where a plugin system exists (Claude, Codex, Gemini). Cursor: bootstrap **copies** `.claude/skills` → `.agents/skills` with the generated marker, `mtk-doctor` reports drift, `setup-refresh` regenerates. No symlinks (Windows checkouts) |
| D4 | MTK-only frontmatter keys | Move under `metadata.mtk-*`; one migration script; `skills-ref validate` becomes a validator gate |
| D5 | MCP bundle distribution | GitHub release asset; `mtk-doctor --fix` fetches it. No npm publish |
| D6 | Skill renames | `claude-md-audit` → `instructions-audit`, `claude-md-capture` → `instructions-capture`; router keeps "claude.md" synonyms |
| D7 | Version | Train ends in **8.0.0** |

## Out of scope

- Porting the `Workflow` (`templates/workflows/*.workflow.js`) orchestration to other harnesses — `MTK_SUBAGENT_DISPATCH=0` inline-MAX is the portable path; revisit when Codex subagents stabilise.
- `Artifact` publishing on non-Claude harnesses — stays Claude-only behind `MTK_ARTIFACT_PUBLISH`.
- A shared permissions `deny` list across harnesses — only Gemini (`excludeTools`) has an equivalent; the PreToolUse `security-gate` is the portable enforcement and already covers the dangerous-command class.
- Tech-stack skills and reference content — untouched; they are already harness-neutral.

## Sources consulted (2026-09-21)

Claude Code memory docs (`code.claude.com/docs/en/memory`, `…/skills`); Agent Skills spec (`agentskills.io/specification`); Codex hooks, subagents, plugins (`learn.chatgpt.com/docs/hooks`, `…/agent-configuration/subagents`, `developers.openai.com/plugins/build/plugins`); Cursor hooks, skills, subagents (`cursor.com/docs/agent/hooks`, `…/skills`, `…/context/subagents`); Gemini CLI hooks reference and extension reference (`geminicli.com/docs/hooks/reference/`, `…/extensions/reference/`); OpenCode skills/rules docs via search.
