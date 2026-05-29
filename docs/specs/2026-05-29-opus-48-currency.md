# Spec — Opus 4.8 Currency Pass (v7.10.2)

Date: 2026-05-29
Slug: opus-48-currency
Scope: **doc-currency + diagnostic tweak + forward-looking integration spec** (no breaking changes)

## Summary

Verify MTK still works correctly under Opus 4.8 and current Claude Code, fix the
two genuinely stale items found, and record the native-platform features MTK
predates so a later pass can decide whether to adopt them.

## Verification result — MTK is sound on Opus 4.8

No breakage. The design choices that matter aged well:

- **Model references are aliases, not pinned IDs.** All five reviewer agents use
  `model: opus` / `model: sonnet`. On the Anthropic API `opus` resolves to Opus
  4.8 automatically — MTK picked up the new model with zero changes. No hardcoded
  `claude-opus-4-*` IDs in any skill or agent.
- **`effort:` and `context: fork` frontmatter are still real, honored keys** for
  both subagents and skills (confirmed against current `code.claude.com/docs`).
  MTK's reviewer agents and review skills continue to do exactly what they intend.
- **`mtk-doctor`'s deprecated-model list** (`claude-3-*`, `claude-2`,
  `claude-instant`) is still accurate — no 4.x model is deprecated, so no false
  flags, and a genuinely stale agent would still FAIL.
- **Deferred-tool / `ToolSearch` / `AskUserQuestion` patterns** remain valid.

## Changes made in this pass

| Path | Action | Note |
|---|---|---|
| `docs/parallelism-patterns.md` | edit | "Opus 4.7, Sonnet 4.6" → "Opus 4.8, Sonnet 4.6 and later" (the only stale shippable model claim) |
| `scripts/mtk-doctor.sh` | edit | Comment + PASS-detail note: aliases resolve to latest on Anthropic API but to older versions on Bedrock/Vertex/Foundry; pin `ANTHROPIC_DEFAULT_*_MODEL` there |
| `.claude/manifest.json` | edit | version 7.10.1 → 7.10.2 |
| `.claude-plugin/plugin.json` | edit | version 7.10.1 → 7.10.2 |
| `.claude-plugin/marketplace.json` | edit | version 7.10.1 → 7.10.2 |
| `CHANGELOG.md` | edit | append `[7.10.2]` entry |

Deliberately **not** changed:
- README `v6.3.0 — Opus 4.7 modernization` heading and the `docs/specs|plans/*opus-47*`
  files — these are accurate historical records; rewriting them would falsify history.
- `setup-bootstrap` — it has no model-configuration section, so the Bedrock/Vertex
  note has no natural home there; the doctor (which already inspects agent `model:`
  lines) is the correct single home.

## The one real provider gap (documented, not yet enforced)

On Bedrock/Vertex/Foundry the `opus` alias resolves to **Opus 4.6**, not 4.8 — so
any Moberg/kvika repo running MTK through those providers silently gets an older
model. The doctor now surfaces the `ANTHROPIC_DEFAULT_*_MODEL` pinning advice. A
future pass could make this an active WARN when a provider env var
(`CLAUDE_CODE_USE_BEDROCK` / `CLAUDE_CODE_USE_VERTEX`) is set without a pinned
model ID.

## Forward-looking: native Claude Code features MTK predates

MTK hand-rolls several things the platform now does natively. None of these are
breakage — the manual implementations still work — but they now compete with
first-class features. Adopt deliberately, not reflexively; MTK's value is its
opinionated compliance-first workflow, which the generic primitives do not encode.

| Native feature | What MTK does today | Recommendation |
|---|---|---|
| **Workflow tool** (deterministic multi-agent orchestration) | `subagent-implementation` + parallel reviewer fan-out, hand-rolled via the Agent tool with orchestrator-side drift checks | **Evaluate, don't rush.** MTK's drift micro-checks and Phase-2.5 gates are the differentiator; a Workflow script could host them but rewriting is high-risk. Prototype one phase (e.g. Stage-2 parallel review) behind the existing skill first. |
| **`EnterWorktree`** native tool | `using-git-worktrees` skill scripts `git worktree` by hand | **Low-risk adopt.** Point the skill at the native tool with a bash fallback (S3.3 requires the toolkit work without it). |
| **`effort: xhigh`** (new tier between `high` and `max`) | Agents use `high`/`max` only | **Consider for `compliance-reviewer`** — the deepest adversarial pass. Cheap, additive. |
| **Background sessions / `/loop` / `/schedule`** | Not referenced | **Optional.** Could drive `repo-health` / `spec-drift-detection` on a cadence. Document as a usage pattern, not a code change. |

## Security and compliance impact

None. Doc edits, one diagnostic detail string, and a version bump. No change to
auth, secrets handling, financial-state surfaces, or audit trails.

## Verification

- `bash scripts/validate-toolkit.sh` — must print "Toolkit validation passed."
- `bash scripts/mtk-doctor.sh` — must still PASS the model-ID check.
- `grep -rn "Opus 4\.7" docs/parallelism-patterns.md` — must return nothing.
- Manifest, plugin, and marketplace versions all read 7.10.2.
