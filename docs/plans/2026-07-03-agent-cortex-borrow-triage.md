# Borrow Triage — awesome-agent-cortex neighborhood

> Source-inventory + triage feeding the v7.19.x setup-improvements wave. Not an
> implementation plan yet — this is the "what's worth mining" upstream of a
> `docs/plans/*-borrow*.md` plan. Findings from triage batches get promoted into
> a dated borrow plan once scored.
>
> Created 2026-07-03.

## Origin source (re-sourceable)

- **Repo:** `0xNyk/awesome-agent-cortex` — https://github.com/0xNyk/awesome-agent-cortex
- **Re-fetch:** `WebFetch https://github.com/0xNyk/awesome-agent-cortex` (raw README:
  `https://raw.githubusercontent.com/0xNyk/awesome-agent-cortex/main/README.md`).
- **What it is:** A hybrid awesome-list + practical layer — CC0-licensed catalog of
  the AI-agent ecosystem ("the sovereign agent stack") with real Claude Code
  skills/configs (`/claude`), Codex CLI configs (`/codex`), Cursor rules
  (`/cursorrules`), Hermes agent materials (`/hermes`), MCP servers, agent-memory
  patterns, and production playbooks (Hermes, Solana, context engineering, skills).
- **Why it matters to MTK:** it is the same *shape* as MTK's own surface (skills,
  subagents, hooks, commands, references, rules, memory, MCP, reviewers), so its
  linked repos are a curated feed of things to mine. Also mirrors MTK's competitive
  landscape note ([[project_setup_competitive_landscape]]).

## The 20-repo borrow list

Grouped by borrow theme. Priority = relevance to MTK's own components.
Triage column filled in per batch below.

### A. Direct peers — Claude Code skill/subagent/hook/plugin ecosystems (highest value)

| # | Repo | What it is | Borrow for MTK |
|---|------|-----------|----------------|
| 1 | [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | Canonical CC awesome-list (skills, hooks, slash-commands, orchestrators, plugins) | Category taxonomy, curation bar, discovery structure |
| 2 | [wshobson/agents](https://github.com/wshobson/agents) | Multi-harness marketplace: ~194 agents / 158 skills / 106 commands from single Markdown source | Single-source → multi-harness generation; plugin packaging |
| 3 | [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents) | 100+ subagents across 10 categories | Subagent frontmatter, tool-restriction patterns, taxonomy |
| 4 | [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) | Mega-toolkit: 135 agents/35 skills/42 commands/20 hooks/15 rules/7 templates/14 MCP configs | Breadth of asset types; rule/template packs |
| 5 | [0xfurai/claude-code-subagents](https://github.com/0xfurai/claude-code-subagents) | 100+ production-ready dev subagents | Production agent prompt design, domain coverage |
| 6 | [davepoon/buildwithclaude](https://github.com/davepoon/buildwithclaude) | Hub for skills/agents/commands/hooks/plugins across CC/Desktop/Agent SDK | Cross-surface packaging, discovery/hub UX |
| 7 | [ComposioHQ/awesome-claude-plugins](https://github.com/ComposioHQ/awesome-claude-plugins) | Plugin-system list (commands, agents, hooks, MCP) | `plugin.json`/marketplace conventions |

### B. Rules, system prompts & setup patterns (setup-bootstrap + CLAUDE.md)

| # | Repo | What it is | Borrow for MTK |
|---|------|-----------|----------------|
| 8 | [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) | 1000+ skills portable across CC/Codex/Gemini/Cursor | Skill portability + authoring standards vs. S2.x anatomy |
| 9 | [github/awesome-copilot](https://github.com/github/awesome-copilot) | Community instructions/agents/skills/hooks/workflows for Copilot | Contribution model, instruction/workflow packaging |
| 10 | [dontriskit/awesome-ai-system-prompts](https://github.com/dontriskit/awesome-ai-system-prompts) | System prompts from top tools incl. Claude Code | How harnesses structure system prompts/personas |
| 11 | [EliFuzz/awesome-system-prompts](https://github.com/EliFuzz/awesome-system-prompts) | System prompts + tool definitions from coding agents | Tool-definition / harness-contract patterns |
| 12 | [yzhao062/agent-style](https://github.com/yzhao062/agent-style) | 21 concise writing rules, AGENTS.md-compatible drop-in | Terse ruleset design, AGENTS.md compat |
| 13 | [instructa/ai-prompts](https://github.com/instructa/ai-prompts) | Curated rules for Cursor/Cline/Windsurf/Copilot | Multi-tool rule templating for setup output |
| 14 | [ccplugins/awesome-claude-code-plugins](https://github.com/ccplugins/awesome-claude-code-plugins) | Curated slash-commands, subagents, MCP servers, hooks | Hook patterns, command ergonomics |

### C. Context, harness & memory engineering (context-engineering + auto-memory)

| # | Repo | What it is | Borrow for MTK |
|---|------|-----------|----------------|
| 15 | [ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) | Harness engineering: tools, patterns, evals, memory, MCP, permissions, observability, orchestration | **Most philosophically aligned** — evals, permission models, gates |
| 16 | [jihoo-kim/awesome-context-engineering](https://github.com/jihoo-kim/awesome-context-engineering) | Libraries: long-term memory, MCP, RAG/prompt compression, multi-agent | Context-window budgeting vs. INDEX.md wake-up layer |
| 17 | [Meirtz/Awesome-Context-Engineering](https://github.com/Meirtz/Awesome-Context-Engineering) | Survey: prompt eng → production context systems | Taxonomy + production patterns for context-report |
| 18 | [IAAR-Shanghai/Awesome-AI-Memory](https://github.com/IAAR-Shanghai/Awesome-AI-Memory) | Memory-native system design for LLMs/agents | Memory architectures for file-based auto-memory + lessons |

### D. Ecosystem breadth (parts of the origin list MTK doesn't cover)

| # | Repo | What it is | Borrow for MTK |
|---|------|-----------|----------------|
| 19 | [wong2/awesome-mcp-servers](https://github.com/wong2/awesome-mcp-servers) | Curated MCP server catalog | Which servers to recommend/bundle at setup |
| 20 | [kyrolabs/awesome-agents](https://github.com/kyrolabs/awesome-agents) | Broad AI-agent framework list | Landscape framing + categorization approach |

---

## Triage

Batches run one at a time; each repo gets: scale/recency signal, top borrowable
patterns mapped to an MTK component, and a borrow verdict (ADOPT / ADAPT / WATCH / SKIP).

### Synthesis — what to build next (all 3 batches) ✅

**The meta-finding:** across 20 repos, almost none of the *content* (persona agents, thin
skills, leaked prompts, research papers) is worth copying — MTK's reviewers, skill anatomy,
evidence gates and verification loop are ahead of the field. The borrow value is concentrated
in **tooling and conventions** from a handful of repos. Star count did not predict value:
the two ~27k★ lists (awesome-agent-skills, awesome-claude-code) were SKIP/WATCH; the useful
sources were `github/awesome-copilot` (build tooling), `wshobson/agents` (eval harness), the
two system-prompt archives (tool-contract phrasing), and `awesome-harness-engineering` (routing).

**Ranked shortlist to promote into a `docs/plans/*-borrow*.md` implementation plan:**

| Rank | Borrow | Source(s) | MTK component | Cost | Verdict |
|---|---|---|---|---|---|
| 1 | **Skill-eval lane** — static rubric + LLM-judge F1 on synthetic trigger/no-trigger prompts + **negative routing examples** | wshobson/agents, awesome-harness-engineering | `evals/`, `validate-toolkit.sh`, `writing-skills`, `/mtk` router | Med | ADAPT |
| 2 | **Compute manifest+README from disk; JSON-schema-validate frontmatter** — kills C0.1/C0.2 drift class | github/awesome-copilot | `manifest.json`, `validate-toolkit.sh`, C0.3 gate | Med | ADAPT |
| 3 | **Guardrails travel with the capability** — per-tool "what/how/when-AND-when-NOT" in every reviewer + dispatch contract; scoped-delete-only fences | dontriskit, EliFuzz | subagent dispatch contract, reviewer subagents | Low | ADOPT |
| 4 | **Conflict-superseding memory writes** — mark old fact stale, don't append duplicate | IAAR-Shanghai | auto-memory, lessons | Low | ADOPT |
| 5 | **Output-style anti-pattern list** in generated CLAUDE.md + terminology lint (9 LLM tics) | yzhao062/agent-style | setup-bootstrap, terminology lint | Low | ADOPT |
| 6 | **Multi-harness rule emission** — `globs`-scoped `.mdc`/`.windsurfrules`/copilot-instructions from CLAUDE.md source | instructa/ai-prompts | `generate-tool-configs.sh` | Med | ADAPT |
| 7 | **Per-stack security-gated MCP shortlist** (GitHub, Context7, Sentry, Playwright, read-only PG; ADO gated) | wong2/awesome-mcp-servers | `docs/recommended-tooling/*`, setup-bootstrap | Low | ADAPT |
| 8 | **Name the context model** — Write/Select/Compress/Isolate + memory content-type tag (episodic/semantic/procedural) + staleness dating | jihoo-kim, Meirtz, IAAR | `context-engineering`, auto-memory | Low | ADAPT |
| 9 | **Explicit `model:` tiers + `## Quality Checklist`** in reviewer/implementer frontmatter (pin current IDs) | VoltAgent-subagents, 0xfurai | dispatch contract, reviewer subagents | Low | ADAPT |
| 10 | **CLAUDE.md archetype seed skeletons** (stack+size fallback when full audit isn't warranted) | rohitg00 | setup-bootstrap | Low | ADAPT |

**Recommended first wave (highest leverage / lowest cost):** #3 (guardrails-in-capability),
#4 (superseding writes), #5 (output-style tics) — all Low cost, all fix known MTK failure modes
(v7.14 out-of-scope edit, v7.10.3 deletion, append-only memory bloat, prose tics). Then #1 + #2
as the larger structural investments (a real eval/validation upgrade).

**Deferred / second-pass borrow-source leads** (surfaced during triage, not yet triaged):
`maestro-orchestrate`, `security-sweep`, `backlog` (via ComposioHQ); `agentcairn`, `Selvedge`
(via awesome-claude-code); read awesome-copilot's `eng/` + `.schemas/` directly as a reference impl.

### Batch 1 — Direct peers (repos 1–7) ✅

**Headline:** the *content* in these repos (persona agents, thin skills) is not worth
copying — MTK's reviewers/skills are more sophisticated. The value is in the **tooling
around the content** (esp. wshobson's `plugin-eval`) and a few cheap conventions.

| # | Repo | Verdict | Highest-leverage borrow |
|---|------|---------|-------------------------|
| 1 | hesreallyhim/awesome-claude-code | WATCH | Link directory (~48k★), not a pattern source — use as a **shortlist generator** for more borrow-sources |
| 2 | wshobson/agents | **ADAPT** | `plugin-eval` 3-layer skill scoring (static rubric + LLM-judge F1 on synthetic triggers + Monte-Carlo activation) |
| 3 | VoltAgent/awesome-claude-code-subagents | WATCH | Least-privilege **tool matrix by agent role** as a lint-checkable rule |
| 4 | rohitg00/awesome-claude-code-toolkit | WATCH | CLAUDE.md **archetype seed templates** (minimal→enterprise + monorepo/python/fullstack); counts are padded |
| 5 | 0xfurai/claude-code-subagents | WATCH | `## Quality Checklist` embedded in each agent = checkable acceptance bar |
| 6 | davepoon/buildwithclaude | WATCH | Polymorphic `source` in marketplace.json (local path OR `{source:github,repo}`) |
| 7 | ComposioHQ/awesome-claude-plugins | WATCH | `x-`namespaced extension field in plugin.json for MTK-specific metadata |

**Top borrows to promote into a plan (ranked):**

1. **[ADAPT] Skill-eval lane from wshobson `plugin-eval`** → `evals/` + `validate-toolkit.sh` +
   `writing-skills`. Static weighted rubric (frontmatter / progressive-disclosure /
   portability / token-budget) + LLM-judge F1 on ~10 synthetic trigger/no-trigger prompts.
   Catches the "skill won't fire when it should / fires when it shouldn't" failure mode our
   structural validator can't see. *Skip the Monte-Carlo layer (cost/deps).* **Highest leverage in batch.**
2. **[ADOPT] "SKILL.md is navigation only" rule** → skill-authoring (S2). Formalize a hard
   token cap + push deep content to `references/`. We already split references; this makes it a rule.
3. **[ADOPT/ADAPT] Least-privilege tool matrix by role** → subagent authoring +
   validate-toolkit. Read-only reviewers = `Read,Grep,Glob`; research lanes add WebFetch/Search;
   implementers full. Make it lint-checkable. (Confirms existing MTK convention; adds enforcement.)
4. **[ADAPT] Explicit `model:` tiers in reviewer/implementer frontmatter** → dispatch contract.
   Opus for compliance/architecture/security review, cheaper tiers for mechanical lanes. **Pin
   current model IDs, don't copy their dated ones** (0xfurai's `claude-sonnet-4-*` pin is an anti-pattern).
5. **[ADAPT] `## Quality Checklist` block in each reviewer subagent** → verification-before-completion.
   Turns verdicts from vibes into checkable acceptance criteria.
6. **[ADAPT] CLAUDE.md archetype seed skeletons** → setup-bootstrap. Optional stack+size-keyed
   fallback when a full audit isn't warranted (our bespoke audit stays the default/stronger path).
7. **[ADAPT, only if multi-plugin] Polymorphic `source` + `x-` extension fields** →
   marketplace.json / plugin.json. Lets MTK federate other internal Moberg repos without vendoring.
8. **[WATCH] Auto pre-compact hook trigger** → hooks + handoff skill. We have the handoff *skill*
   but no automatic pre-compact trigger — noted gap.

**New borrow-source leads surfaced (funnel for a later batch):** `agentcairn`, `Selvedge`
(memory/context, via awesome-claude-code); `maestro-orchestrate` (22-subagent orchestration),
`security-sweep` (OWASP 2025 + prompt-injection), `backlog` (event-sourced cross-session task
store, 24 MCP tools) — all via ComposioHQ list.

**Not worth it:** copying persona-agent libraries (breadth-over-depth zoos), flat `category:`
taxonomies (our INDEX axes are richer), building a bespoke install CLI (we ride the native plugin manager).

### Batch 2 — Rules/system-prompts/setup + skills (repos 8–14) ✅

**Headline:** best batch so far. `github/awesome-copilot`'s **build/validation tooling**
(generate manifest+README from disk, schema-validated frontmatter) is more rigorous than
our `validate-toolkit.sh`. The two system-prompt archives converge on one idea: **bake
guardrails INTO each tool/subagent capability, with an explicit "when NOT to use" clause** —
which directly targets our known out-of-scope-edit (v7.14) and destructive-deletion (v7.10.3)
failure modes. Two entries (8, 14) are pure link directories → SKIP.

| # | Repo | Verdict | Highest-leverage borrow |
|---|------|---------|-------------------------|
| 8 | VoltAgent/awesome-agent-skills | **SKIP** | ~27k★ but zero substance — link list, portability claim unimplemented |
| 9 | github/awesome-copilot | **ADAPT** | Generate manifest+README from the file tree + **JSON-schema-validated frontmatter** per component |
| 10 | dontriskit/awesome-ai-system-prompts | **ADAPT** | Per-tool **"what / how / when-AND-when-NOT"** contract clause |
| 11 | EliFuzz/awesome-system-prompts | **ADAPT** | Guardrails (line caps, scoped-delete-only) baked **into the tool description** |
| 12 | yzhao062/agent-style | **ADAPT** | 9 field-observed **LLM anti-patterns** (no em-dash-as-punctuation, no bullet inflation, no "Additionally/Furthermore/Moreover") |
| 13 | instructa/ai-prompts | **ADAPT** | `globs`-scoped `.mdc` emission → generate Cursor/Windsurf/Copilot rules from the CLAUDE.md source |
| 14 | ccplugins/awesome-claude-code-plugins | **SKIP** | Link directory, no hook code/lifecycle at all |

**Top borrows to promote into a plan (ranked):**

1. **[ADAPT] Compute the manifest + README from the file tree; schema-validate frontmatter**
   (from awesome-copilot's `eng/` + `.schemas/`). → `manifest.json` (C0.1/C0.2), `validate-toolkit.sh`,
   skill-anatomy gate (C0.3). Today MTK hand-maintains the manifest and its structural check is
   stringly-typed bash. A per-component JSON Schema (skill/agent/hook) + a derive-from-disk step
   **eliminates the whole C0.1/C0.2 drift bug class** and gives contributors precise errors. **Highest leverage in batch.**
2. **[ADOPT] Tool/subagent guardrails travel with the capability** — every reviewer subagent and
   the subagent dispatch contract states, per granted tool: *what it does / how to use it / when to
   use it AND when NOT to*. (dontriskit + EliFuzz converge.) → dispatch contract, reviewer subagents,
   `subagent-implementation`. Cheap; directly curbs the **out-of-scope action** (v7.14 hallucinated
   README edit) and **scoped-delete-only** fences map to our "NEVER delete data files" rule + the v7.10.3 regression.
3. **[ADOPT] Output-style anti-pattern list in generated CLAUDE.md + terminology lint** — the 9
   field-observed LLM tics from `agent-style`. → setup-bootstrap CLAUDE.md generation + terminology lint.
   Targets the exact prose tics MTK-authored output exhibits; several overlap our existing terminology lint.
4. **[ADOPT/ADAPT] Multi-harness rule emission** — `generate-tool-configs.sh` emits one `globs`-scoped
   `.mdc` (Cursor), `.windsurfrules`, `.github/copilot-instructions.md` per MTK rule/reference, globs
   derived from stack detection. (instructa proves the target formats; we already have the generator scaffolding.)
   → cross-tool config generation. Answers "should MTK generate for non-Claude harnesses?" → yes.
5. **[ADAPT] `applyTo:`/`globs` machine-enforceable scoping under the INDEX wake-up prose** — add a
   path-glob axis to rules so a rule auto-attaches by edited-file pattern, not only by agent judgment.
   → `rules/INDEX.md` + per-stack references frontmatter.
6. **[ADAPT] Idempotent import-marker merge** for generated config files (never overwrite; append/merge
   behind a marker). → `generate-agents-md.sh` / `generate-tool-configs.sh`, aligns with C0.7 CLAUDE.md protection.
7. **[ADAPT] Canonical 6-section ordering + "state the finding, don't soften" refusal framing** for
   *agent* prompts (which have no anatomy rule today, unlike skills). → `writing-skills` (extend to agents),
   adversarial reviewer personas. Aligns with [[design_review_persona]].

**New leads:** read awesome-copilot's `eng/` build scripts + `.schemas/` directly as a reference
implementation before building our own; mine ccplugins' "Git Workflow" (14) + "Automation/DevOps" (5)
entries for real hook implementations one hop downstream.

**Not worth it:** high-star link lists with no build/validation engineering (8, 14); mirroring
community-authored per-stack rule *content* (our dotnet refs are deeper/team-owned — mine for TS/React gaps only).

### Batch 3 — Context/memory/harness + ecosystem (repos 15–20) ✅

**Headline:** these are research/reading lists — **no code to vendor**, and the memory/RAG
systems they cite assume vector/graph DBs (out of scope for a markdown+bash plugin). Value is
**vocabulary + a few file-implementable ideas**. `awesome-harness-engineering` is the most
thesis-aligned repo in the whole sweep but ~70% restates what MTK already does; its one standout
is negative-example skill routing. The real self-contained wins here are **conflict-superseding
memory writes** and a **per-stack MCP shortlist**.

| # | Repo | Verdict | Highest-leverage borrow |
|---|------|---------|-------------------------|
| 15 | ai-boost/awesome-harness-engineering | **ADAPT** | **Negative examples in skill-routing manifests** (measured 73%→85% routing accuracy) |
| 16 | jihoo-kim/awesome-context-engineering | WATCH | **Write / Select / Compress / Isolate** four-mode taxonomy as the context-engineering spine |
| 17 | Meirtz/Awesome-Context-Engineering | **ADAPT** | Taxonomy + "context = complete information payload at inference time" definition; memory tri-layer names |
| 18 | IAAR-Shanghai/Awesome-AI-Memory | **ADAPT** | **Conflict-driven superseding writes** (mark old fact stale, don't append duplicate) |
| 19 | wong2/awesome-mcp-servers | **ADAPT** | Per-stack MCP shortlist (GitHub, Context7, Sentry, Playwright, Azure DevOps, read-only DB) |
| 20 | kyrolabs/awesome-agents | WATCH | Ecosystem taxonomy as a **positioning foil** for the README ("toolkit, not framework") |

**Top borrows to promote into a plan (ranked):**

1. **[ADOPT] Negative examples in skill routing** — each SKILL.md / router entry encodes explicit
   "NOT this skill when…" boundaries. → `/mtk` router, `writing-skills` (CSO), router fixtures/evals.
   Measurable against existing `run-fixtures.sh`/`run-evals.sh`; fixes the misroute-on-adjacent-intent
   weakness every NL router has. **Highest leverage in batch, cheap.**
2. **[ADOPT] Conflict-driven superseding memory writes** — when a new fact contradicts an existing
   one, link + mark the old file stale instead of appending a duplicate. → auto-memory write policy,
   `promote-lesson`/`lesson-mining`. Pure-markdown; closes the biggest structural gap in append-only memory.
3. **[ADAPT] Per-stack, security-gated MCP recommendation shortlist** — fold ~5 vendor-official
   servers into `docs/recommended-tooling/{dotnet,python,typescript}.md` + setup-bootstrap, each as
   `server → what for → install one-liner → security note`. Shortlist: **GitHub, Context7, Sentry,
   Playwright, read-only Postgres**; **Azure DevOps** gated on "team uses ADO". Recommend DB servers
   **read-only** (write access = foot-gun). Skip Git/Filesystem for CC (native tools cover them).
4. **[ADAPT] Name the context-engineering mental model** — adopt **Write/Select/Compress/Isolate** +
   a one-line "context = complete information payload at inference time" definition at the head of the
   `context-engineering` skill/refs. Maps onto existing pieces (Write=auto-memory/lessons,
   Select=INDEX+reference-on-demand, Compress=output-compression, Isolate=subagent dispatch). Labeling win, zero deps.
5. **[ADAPT] Memory lifecycle: content-type tag + staleness dating** — add a cross-cutting nature tag
   (episodic/semantic/procedural) alongside the provenance `type`, and a `last_confirmed` date +
   suggest-only "archive stale facts" sweep. → auto-memory + lessons. **Suggest-only; never auto-delete.**
6. **[WATCH] Intent/risk-classified permissions** (`readOnlyHint`/`destructiveHint`, 5-layer eval order) —
   good mental model to document, but full realization depends on Claude Code's native `canUseTool` layer,
   not plugin-shaped. → tool-permission model docs.
7. **[ADAPT] Positioning foil** — use kyrolabs' taxonomy in the README to place MTK *outside* "agent
   frameworks" and *inside* the thin "verification/quality tooling" niche. → README/positioning ([[project_positioning]]).

**Not worth it:** vendoring any cited memory/RAG system (mem0/letta/graphiti/MemGPT/GraphRAG — all
need vector/graph infra); LLMLingua-style token compression (needs a scorer model — keep only the
heuristic); the 700-entry MCP firehose or academic paper lists.
