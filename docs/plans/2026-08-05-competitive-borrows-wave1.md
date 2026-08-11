# Plan — Competitive Borrows Wave 1

Spec: `docs/specs/2026-08-05-competitive-borrows-wave1.md`
Sidecar: `docs/specs/2026-08-05-competitive-borrows-wave1.json`
Rigor: **HIGH** (score 11; hard-trigger floor also applies — 3 batches, ≥6 non-mechanical files)

## Batch B0 — Blocking pre-flight (engineer decision required)

`scripts/poison-lint.sh:91` calls `mapfile`, a bash 4+ builtin. macOS ships bash 3.2, so
`validate-toolkit.sh` exits non-zero on this machine **before any change in this plan**.

- **Boundary:** `scripts/poison-lint.sh` only.
- **Acceptance:** `bash scripts/validate-toolkit.sh` reaches its own summary rather than
  aborting on the poison-lint step.
- **Decision needed at the gate:** fix it inside this run (one-line `while read` swap), or
  waive SC7/C0.8 and accept that this work cannot be validated end-to-end on macOS.
  Not silently worked around either way.

## Batch A — B1: published benchmark results

**Rationale.** Seven of the ten repos in the August sweep publish `results.json` with
declared exclusions. MTK publishes nothing. The machinery already exists; only emission and
per-section attribution are missing.

| Step | File | Change |
|---|---|---|
| A1 | `scripts/run-benchmarks.sh` | Add `section()` helper + `SECTION_PASS`/`SECTION_FAIL` accumulators; each `printf '\n== X ==\n'` becomes a tracked section |
| A2 | `scripts/run-benchmarks.sh` | Fix `VAL_EXIT=$?` — capture the real exit of `validate-toolkit.sh` instead of the always-0 assignment status |
| A3 | `scripts/run-benchmarks.sh` | Emit `benchmarks/results.json` via `python3` heredoc (S3.3 forbids `jq`) |
| A4 | `benchmarks/README.md` | Methodology; **what the numbers exclude** (no LLM-behavior measurement, no cross-model coverage, single-machine timings) |
| A5 | `.claude/manifest.json` | Register `benchmarks/results.json` + `benchmarks/README.md` |

- **Boundary:** does not touch hooks, skills, or agents.
- **Acceptance (SC3, SC4):** `bash scripts/run-benchmarks.sh` writes a `results.json` whose
  per-section counts sum exactly to the terminal summary, with a non-empty `excludes[]`;
  the validate assertion reflects a real exit code.

## Batch B — B2: trigger-bound rule delivery

**Rationale.** `.claude/rules/INDEX.md` already carries `paths`/`decision`/`topic`/`scope`
and *describes* just-in-time loading — as an instruction the model may skip. nunchi measured
−42.5% start tokens by binding rules to PreToolUse triggers instead. One hook converts MTK's
existing metadata into a mechanism.

| Step | File | Change |
|---|---|---|
| B1a | `hooks/rule-trigger.sh` | PreToolUse hook. Read `.claude/rules/triggers.index`; on `tool` + `pattern` (+ optional `path`) match, read the rule's source and emit it. Fail-open on every error. Exit immediately if the index is absent |
| B1b | `.claude/rules/rule-frontmatter.md` | Contract: `trigger.tool`, `trigger.pattern`, `trigger.path`, `strength` (`inject` \| `require-read` \| `block`), delivery-once semantics, re-arm |
| B1c | 4 × `.claude/rules/*.md` | Add `trigger:` + `strength: inject` frontmatter (advisory by default — no behavior change to existing sessions) |
| B1d | `scripts/build-rule-index.sh` | Also emit `.claude/rules/triggers.index` (tab-separated: name, tool, pattern, path, strength, source) |
| B1e | `hooks/hooks.json` | PreToolUse entry + `SessionStart` matcher `compact` re-arm entry, `${CLAUDE_PLUGIN_ROOT}` paths, timeout |
| B1f | `.claude/settings.json` | Mirror for this dev checkout (S3.6); double-run guard handles overlap |
| B1g | `scripts/validate-toolkit.sh` | Assert `triggers.index` is in sync with rule frontmatter (S3.10) |
| B1h | `.claude/manifest.json` | Register the new hook, reference, and index |

- **Boundary:** no skill or agent files.
- **Acceptance (SC1, SC2):** new BENCHMARK 8 section proves match delivers, non-match is
  silent, and corrupt/missing index exits 0.
- **Risk control:** every rule ships `strength: inject`. Nothing blocks in this batch.

## Batch C — B3: reviewer abstention semantics

**Rationale.** The verdict enum is `PASS | NEEDS_CHANGES`. A reviewer that errors, times
out, or returns garbage has no schema-valid way to say so, and no orchestrator rule consumes
the prose `BLOCKED`/`NEEDS_CONTEXT` escalation the agents already describe. CodeJury's rule:
*a missing juror must never read as a clean one.* Today, in MTK, it does.

| Step | File | Change |
|---|---|---|
| C1 | `.claude/references/review-finding-schema.md` | Verdict enum → `PASS \| NEEDS_CHANGES \| ABSTAINED`; add `abstention: {reason, stage, checked}`; add the **Lane Accounting** section |
| C2 | `.claude/skills/code-review-and-quality/SKILL.md` | New step: enumerate dispatched lanes, require each to return `PASS`/`NEEDS_CHANGES`/`ABSTAINED`; an unreturned lane is `ABSTAINED(no-response)`; overall verdict cannot be `PASS` with any abstained lane |
| C3 | `.claude/skills/implement/SKILL.md` | Phase 4: same accounting requirement at the orchestrator level |
| C4 | 6 × `.claude/agents/*.md` | Replace prose-only self-escalation with an instruction to emit `"verdict": "ABSTAINED"` + `abstention.reason` in the JSON block |
| C5 | `tests/pressure-tests/reviewer-abstention.md` | Adversarial: reviewer times out and the orchestrator is tempted to report "no findings"; agent emits empty `findings[]` on a lane it could not read; 2-of-3 lanes return and the third is silently dropped |
| C6 | `.claude/manifest.json` | Register the pressure test |

- **Boundary:** documentation/contract change only — no executable code.
- **Acceptance (SC5, SC6):** schema documents `ABSTAINED`; all six agents instruct emitting
  it; both orchestrators carry the accounting rule; pressure test covers the three traps.

## Execution order and gates

```
B0 (engineer decision)
  → A  → checkpoint: run-benchmarks.sh, results.json written
  → B  → checkpoint: run-benchmarks.sh (incl. new BENCHMARK 8), build-rule-index.sh --check
  → C  → checkpoint: validate-toolkit.sh
  → Phase 3.5 drift check vs sidecar change_manifest
  → Phase 4 review (see deviation below)
  → Phase 6 cleanup → Phase 7 compound
```

Batches are ordered by independence: A touches only benchmarks, B only hooks/rules, C only
review contracts. No batch depends on another's output, so a failure in one does not strand
the others.

## Declared ceremony deviation

Rigor HIGH prescribes the **subagent implementation path** (one fresh implementer per batch)
and Phase 4 **reviewer agents**. The engineer's standing instruction for this session is
*"Do not call the AgentTool unless the user requested it."*

The explicit user standard wins — MTK's own rule is that ceremony never overrides explicit
user standards. Consequence, stated plainly rather than hidden:

- Batches run **inline** in the orchestrator context. Reduced context isolation; the drift
  micro-check after each batch is the compensating control.
- Phase 4 runs **inline against the same reviewer checklists** rather than as forked agents.
  A self-review is weaker than an independent one — and it is worth noting that Batch C
  exists precisely because MTK had no way to record "this lane did not really run."
  This deviation is itself an abstention-shaped event and is recorded as one.
