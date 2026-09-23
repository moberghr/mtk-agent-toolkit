# ECC Harness Adapters — Research Note

Maintainer reference for the multi-harness migration (`docs/plans/2026-09-21-multi-harness-migration.md`,
workstreams WS2 and later). A comparable open-source project ships a working per-harness
installer, hook adapter, and cross-harness memory design; this note extracts what is
transferable to this toolkit's bash-only, plugin-distributed architecture and what is not,
studied at that project's commit `bf70150` on 2026-09-23. File paths cited as
`ECC:<path>:<line>` point into that read-only source tree, not into this repo.

## 1. Adapter layout

The source project keeps one source tree (rules, skills, agents, commands, hooks) and layers a
per-target **install adapter** over it rather than maintaining parallel per-harness copies
(`ECC:docs/SELECTIVE-INSTALL-ARCHITECTURE.md:20-43`). Each adapter is a plain object —
`rootSegments` (where the target's config directory lives, e.g. `['.cursor']`), an
`installStatePathSegments` (where that target records what it installed),
`nativeRootRelativePath`, and a `planOperations(input, adapter)` function that turns a
resolved module list into a list of copy/merge/generate operations
(`ECC:scripts/lib/install-targets/cursor-project.js:56-210`,
`ECC:scripts/lib/install-targets/antigravity-project.js:20-30`,
`ECC:scripts/lib/install-targets/kimi-project.js:46-50`). A `registry.js` holds the frozen
adapter array and dispatches by target name (`ECC:scripts/lib/install-targets/registry.js:18-91`).

Content is described once in a **module manifest** (`manifests/install-modules.json`: id, kind,
description, `paths`, `targets`, `dependencies`, `defaultInstall`, `cost`, `stability`) and
grouped into **install profiles** (`manifests/install-profiles.json`: named bundles like
`minimal`, `core`, `opencode`, each a list of module ids with a one-line description). Planning
is pure and read-only — `planInstallTargetScaffold` returns operations without touching disk;
execution and install-state recording are separate steps
(`ECC:docs/SELECTIVE-INSTALL-ARCHITECTURE.md:131-150`). Lifecycle commands (`list-installed`,
`doctor`, `repair`, `uninstall`) reuse the same recorded operations rather than re-deriving state.

For Codex specifically, the project does **not** try to make the full skill set portable — it
hand-curates a narrow subset under `.agents/skills/`, gated by a CI test that checks every
`SKILL.md` frontmatter against an explicit allowlist (`allowed-tools`, `description`, `license`,
`metadata`, `name` — nothing else) and requires a sidecar `agents/openai.yaml` per skill with a
`display_name`, a 25–64 char `short_description`, and a `default_prompt` that names the skill
(`ECC:tests/ci/codex-skill-surface.test.js:12-18,80-82,95-117`).

## 2. Per-harness mapping table

| Harness | Config root | Source | Generated vs hand-maintained |
|---|---|---|---|
| Claude Code | `.claude/` | native, primary | Hand-maintained; other targets derive from it. |
| Codex | `.codex/`, `~/.codex/` | `sync-ecc-to-codex.sh` (`ECC:scripts/sync-ecc-to-codex.sh:1-52`) + a hand-curated `.agents/skills/` subset | Generated (prompts from `commands/*.md`, marker-merged `AGENTS.md`, TOML-merged MCP config) plus a hand-authored skill allowlist. |
| Cursor | `.cursor/` | `cursor-project.js` adapter | Fully generated: rules flattened to `.mdc`, agents renamed/prefixed (`ecc-*`) to avoid collisions, root `AGENTS.md` deliberately **not** copied because Cursor treats a nested `AGENTS.md` as directory-scoped project identity (`ECC:scripts/lib/install-targets/cursor-project.js:138-142`). |
| Antigravity | `.agents/` | `antigravity-project.js` adapter | Generated; only `rules/commands/agents/skills` path prefixes are supported, everything else is filtered out (`ECC:scripts/lib/install-targets/antigravity-project.js:11-18`). |
| Kimi | `.kimi-code/` | `kimi-project.js` adapter | Generated; MCP config is JSON-merged into the target's own `mcp.json` rather than overwritten (`ECC:scripts/lib/install-targets/kimi-project.js:24-42`). |

The project's own README states the same asymmetry MTK's WS0 spike found independently: Claude
Code is the "primary reference," Codex/Cursor/OpenCode are "partial" parity, and GitHub Copilot
is "not a parity target" (`ECC:README.md:1391-1408`).

## 3. Hook protocol adaptation

Cursor exposes more hook events than Claude Code (20 vs 8 in the source project's count) and a
different payload/output shape. Rather than reimplementing hook logic per harness, a thin
`.cursor/hooks/adapter.js` reads Cursor's stdin JSON, remaps it into a Claude-shaped
`{tool_input, tool_output, transcript_path, _cursor: {...}}` object, and shells out to the
existing `scripts/hooks/*.js` script via `execFileSync`, forwarding an `exit 2` as a block
(`ECC:.cursor/hooks/adapter.js:28-61`). A profile knob (`ECC_HOOK_PROFILE`:
`minimal|standard|strict`) and a deny-list (`ECC_DISABLED_HOOKS`) gate which hooks actually run
per install (`ECC:.cursor/hooks/adapter.js:63-79`).

For Codex, the project does not adapt every hook — it ships a "native reviewed subset with
explicit trust" (`ECC:README.md:1394`) rather than the full hook set, because Codex's own
approval reviewer intercepts dangerous shell commands before any hook runs, and because Codex
has no `Read`/`Grep`/`Glob` tool surface (it reads files via shell `cat`), so any hook keyed on
those tool names is unreachable there.

## 4. Capability-surface selection rule

The project has a written decision order for "does this belong in a rule, a skill, an MCP
server, or a plain script" (`ECC:docs/capability-surface-selection.md:15-29`):

1. Always-on, no model judgment → a **rule**.
2. On-demand playbook/workflow → a **skill**.
3. Structured, repeated, cross-client interface → **MCP**.
4. One-shot deterministic local action → a **CLI/script**, optionally wrapped by a skill.
5. One narrow remote call inside a larger workflow → a direct **API** call.

Its cost bias, when two surfaces are both viable, is: smaller runtime surface, lower token
overhead, fewer external moving parts, no new third-party dependency
(`ECC:docs/capability-surface-selection.md:100-109`). This is a routing rubric, not a manifest
schema — it maps to MTK's existing skill/rule/reference split but MTK does not currently have an
MCP-vs-skill decision rule written down anywhere; that is the one piece worth borrowing on its
own merits, independent of the harness migration.

## 5. Memory Vault trust model

The project's cross-harness memory design (`docs/design/ecc-memory-vault.md`) is the most
directly relevant precedent for anything MTK does with `promote-lesson` or a shared lessons
store across harnesses, so it is documented in full here even though it is outside WS1–WS7:

- **Scopes.** `project` (repo-local, `.ecc/memory/`), `team` (same tree, meant to be reviewed
  before commit), `user` (`~/.ecc/memory/`, cross-repo, recalled only on explicit request)
  (`ECC:docs/design/ecc-memory-vault.md:86-113`).
- **Document contract.** Each memory is a Markdown file with strict JSON-valued YAML
  frontmatter: `schema: "ecc.memory.v1"`, `id`, `title`, `kind`, `scope`, `trust`, `status`,
  `source_harness`, `target_harnesses`, `tags`, `links`, timestamps
  (`ECC:docs/design/ecc-memory-vault.md:115-142`).
- **Create-only.** Writes never overwrite an existing memory id; supersession is a new document
  linking to the old one (`ECC:docs/design/ecc-memory-vault.md:24-25`).
- **`trust: "unreviewed"` by construction.** Every first-release write is unreviewed; there is no
  automated promotion path to rule/skill/policy status — "a shell-capable agent cannot be
  treated as an independent human approval boundary" is stated as the reason
  (`ECC:docs/design/ecc-memory-vault.md:156-163`).
- **Fail-closed `.gitignore`.** The project scope writes a `*\n!.gitignore\n` gitignore file on
  first init; if that file already exists with *different* content, every subsequent write
  throws rather than silently accepting a weakened ignore file
  (`ECC:scripts/lib/memory-vault.js:33,242-260`).
- **`source_harness` bound at server launch, not per-call.** The MCP adapter requires an
  `ECC_MEMORY_HARNESS` env var at process start; that value supplies `source_harness` for every
  write and scopes reads, and a tool-call argument cannot override it — this is what stops one
  harness's MCP client from forging another harness's identity
  (`ECC:docs/design/ecc-memory-vault.md:190-196`).
- **Incomplete scan is an error, never an absence.** A bounded directory scan that hits a
  malformed file, a truncation limit, or a symlink does not silently report "not found" — a
  direct read fails closed with `ECC_MEMORY_INCOMPLETE` (`MEMORY_READ_INCOMPLETE` over MCP)
  rather than returning partial results as if they were complete
  (`ECC:docs/design/ecc-memory-vault.md:36-46`).
- **Handoff body contents.** A `handoff` document is written the same way as any other memory —
  title, body from stdin or a file, `source`/`target` harness — with no special schema beyond
  `kind: "handoff"`; the CLI surface is `ecc memory handoff --from <harness> --target <harness>
  --title <text>` (`ECC:docs/design/ecc-memory-vault.md:169-175`,
  `ECC:docs/COMMAND-AGENT-MAP.md:56`).
- **Runtime dependency.** The CLI and MCP server both require a separately installed
  `ecc-universal` npm package on `PATH`; a bare repo checkout falls back to
  `node scripts/ecc.js memory ...` (`ECC:skills/unified-memory/SKILL.md:14-29`). The skill's own
  frontmatter already puts its one non-spec key under `metadata:` (`metadata.origin: ECC`)
  rather than top-level (`ECC:skills/unified-memory/SKILL.md:1-6`) — the same shape WS4/D4
  proposes for MTK's `metadata.mtk-*` keys, independently arrived at.

## 6. Take / Adapt / Skip

Verdicts are framed against MTK's own constraints: S3.3 (bash/coreutils only, no Node runtime
for hooks — MCP server code is the one named exception), the D1–D7 decisions already resolved in
the migration plan, and the fact that none of this is implemented in MTK yet.

### WS2 — Path & environment abstraction

| ECC mechanism | Verdict | Why |
|---|---|---|
| `mtk_harness()`-equivalent: detect target from env vars, then payload shape | **Take** | ECC's registry dispatches by an explicit `target` string resolved once per invocation, the same shape WS2 already specs for `mtk_harness()`; no new idea, just confirmation the approach works in a shipped tool. |
| Adapter object with `rootSegments`/`installStatePathSegments`/`planOperations` | **Adapt** | ECC's adapters are JS objects calling JS helpers. WS2/WS3's bash equivalent is a lookup table (`hooks/lib/harness-tools.sh`) plus function dispatch — same shape, S3.3-compliant implementation. Do not import the JS pattern verbatim. |
| Per-harness memory/data-home override (`ECC_AGENT_DATA_HOME`, `ECC_MEMORY_PROJECT_ROOT`) | **Take (the idea, not the vars)** | Directly matches WS2's "session-scoped state moves to `${XDG_STATE_HOME}/mtk/<repo-hash>/`" line — confirms an explicit override env var plus a harness-keyed default is the right shape. |

### WS3 — Hooks: one logic, four protocols

| ECC mechanism | Verdict | Why |
|---|---|---|
| Thin per-harness adapter script translating stdin, delegating to shared hook logic (Cursor `adapter.js`) | **Take the shape, not the runtime** | Matches WS3's own design (`hook-io.sh` input/output adapters + `hooks.source.json` → generated per-harness configs) almost exactly. ECC's adapter is Node; MTK's must stay bash per S3.3 — same translate-then-delegate structure, different language. |
| Capability-class dispatch instead of raw tool name (Codex has no `Read`/`Grep`/`Glob`) | **Take** | Independently confirms WS3's `mtk_extract_tool_name` → capability class (`shell\|file-write\|file-read\|search\|other`) design is necessary, not optional — ECC hit the identical Codex gap (no read-tool hook surface) that MTK's own WS0 spike found. |
| Native reviewed hook subset per harness rather than 1:1 porting every hook | **Take** | Matches WS3's own plan: Gemini drops post-compact, Cursor Stop can't hard-block, Copilot/OpenCode get none. ECC ships fewer hooks on weaker harnesses rather than faking parity — same posture MTK's doctor/matrix approach already takes. |
| MCP health tracking driven by a tool-failure event | **Adapt** | MTK's `hooks/mcp-health.sh` records failures from Claude Code's `PostToolUseFailure` event and reads `hook_event_name` from the payload. That event is Claude-only: WS3's harness-neutral event list (session-start/pre-tool/post-tool/pre-compact/post-compact/prompt-submit/stop/subagent-stop) has no failure event, and the WS0 Codex run did not show one. WS3 must either add a `tool-failure` class to `hooks.source.json` with per-harness degradation (no failure event ⇒ no backoff tracking; the PreToolUse advisory simply never fires) or record mcp-health as Claude-only in the harness matrix. |
| `ECC_HOOK_PROFILE` (minimal/standard/strict) + `ECC_DISABLED_HOOKS` deny-list as a per-install knob | **Skip for now** | Adds a second axis of hook-enablement on top of `MTK_HOOKS_TIER2` and the harness-support matrix; not asked for by any WS2/WS3/D-decision, and stacking two enablement knobs is its own source of doctor-drift bugs (see §7). Revisit only if a real team asks for per-harness hook tuning. |

### WS6 — Packaging

| ECC mechanism | Verdict | Why |
|---|---|---|
| One canonical source tree, generated per-target manifests | **Take** | This is WS6's own design already (`generate-manifests.sh` from `.claude/manifest.json`). ECC proves the pattern scales to five-plus targets without content forks. |
| No Codex-specific manifest — Codex reads the Claude plugin manifest directly | **Take (confirms, doesn't add)** | Matches WS6's row verbatim: "Codex reads `.claude-plugin/marketplace.json` + `plugin.json` directly." Independent confirmation from a second project, not a new finding. |
| Hand-curated `.agents/skills/` subset for Codex, CI-gated by an exact frontmatter allowlist | **Adapt** | MTK's D4 already narrows shipped frontmatter to spec-plus-`metadata.mtk-*`, so a full skill set should load under a stricter parser without a hand-picked subset. Worth adapting only the *pattern* — a CI test asserting the allowlist and any generated per-skill sidecar file stay in sync — not the subsetting itself, unless Codex's lenient-but-undocumented parser (WS0: it already loaded MTK's non-spec keys) turns out to regress. |
| `sync-ecc-to-codex.sh`: marker-based `AGENTS.md` merge into `~/.codex/AGENTS.md`, TOML-merged MCP config, global git hooks installer | **Skip** | This is a *global*, `~/.codex`-scoped sync script — a different install model than MTK's per-repo bootstrap. WS6/WS7 already cover the plugin-marketplace path; a competing global-sync script would be a second, divergent install surface. |
| npm-published `ecc-universal` runtime required for the memory CLI/MCP | **Skip** | D5 already rejected npm publish for MTK's own MCP bundle (GitHub release asset + `mtk-doctor --fix` fetch instead) for the same reason ECC's own skill has to warn about it: a separately-installed npm dependency is a silent gap between "skill says it works" and "binary is on PATH." |

### WS7 — Setup, refresh and doctor

| ECC mechanism | Verdict | Why |
|---|---|---|
| Install profiles (`minimal`, `core`, `opencode`, …) as named module bundles, each with a one-line description | **Adapt** | WS7's `.claude/harnesses` multi-select already asks "which harnesses" — ECC's profile *concept* (a harness-appropriate default bundle, e.g. `opencode` profile excluding `hooks-runtime` by default) is worth folding into the non-interactive default rather than adding a second manifest layer MTK doesn't otherwise have. |
| `doctor` reads only durable install-state, not heuristics | **Take** | Matches WS7's doctor design (compare generated files against source, harness recorded in `.claude/harnesses`) — confirms recording *what was installed* beats re-deriving it from file presence. |
| Per-target install-state file (`ecc-install-state.json` under each target's own root) | **Skip as a separate file** | WS7 plans `.claude/harnesses` (protected, one line per harness; not yet implemented) plus the generated-file marker convention; a second per-target JSON state file duplicates that without a stated need. Revisit only if `setup-refresh --check` proves file-marker diffing insufficient. |

*WS1 (instruction layer) / handoff-memory note:* nothing in §6 above is a WS1 recommendation —
`AGENTS.md`-as-canonical is already D2-resolved and ECC reaches the same root file independently
(`ECC:README.md:1403`, "AGENTS.md at root is the universal cross-tool file"), which is
confirmation, not new information. The Memory Vault (§5) is the one piece of this research that
bears on a *different*, unscheduled piece of work — a cross-harness handoff/lessons store — and
is recorded here rather than folded into WS1 because no workstream currently owns it.

## 7. Known ECC pitfalls worth avoiding

- **Branching on an env var nothing sets, instead of the payload field.** The MCP health-check
  hook picks its code path with
  `const eventName = process.env.CLAUDE_HOOK_EVENT_NAME || 'PreToolUse';`
  (`ECC:scripts/hooks/mcp-health-check.js:848`) — but Claude Code hooks deliver the event name in
  the JSON stdin payload (`hook_event_name`), not in an environment variable. Nothing sets
  `CLAUDE_HOOK_EVENT_NAME`, so the `||` fallback fires on every invocation and the
  `PostToolUseFailure` branch is dead code in practice. WS3's hook I/O layer already reads
  `hook_event_name` from the parsed payload, not env — this is a reminder to keep it that way
  when the same script is asked to serve a second harness whose payload key is spelled
  differently, not to add an env-var shortcut "for testing."
- **Two independent hook-enablement knobs.** `ECC_HOOK_PROFILE` and `ECC_DISABLED_HOOKS` sit
  alongside whatever per-hook trust/config state the target harness itself keeps (Codex's own
  `trusted_hash` gate, noted in `docs/harness-support-matrix.md`). A hook can be silently
  disabled by either axis, and neither `doctor` output cited in the source tree cross-checks
  them against each other. WS3/WS7 should keep exactly one enablement axis
  (`MTK_HOOKS_TIER2` plus the harness-recorded tier) rather than adding a second.
- **String-substitution "ports" instead of real adapters.** The harness-support matrix's own
  Codex section already records one instance of this failure mode independently
  (a `.claude/` → `.Codex/`, `CLAUDE.md` → `AGENTS.md` case-substitution conversion that produced
  a reviewer agent citing paths that do not exist). ECC's SELECTIVE-INSTALL-ARCHITECTURE.md
  identifies the same anti-pattern as a design principle to avoid ("a generator must rewrite
  paths, not case"). Treat this as validated twice, not once.
- **A generated sidecar file that CI checks but nothing regenerates automatically.** The Codex
  skill surface test asserts `agents/openai.yaml` exists and matches conventions per skill
  (`ECC:tests/ci/codex-skill-surface.test.js:95-117`), but there is no script cited alongside it
  that derives that file from `SKILL.md` — it reads as hand-maintained and CI-gated rather than
  generate-and-diff. WS6/WS7's own `validate-toolkit.sh`-style "generated configs in sync with
  source" pattern is the stricter version of this; don't regress to a hand-maintained sidecar
  that a validator merely checks for presence.
