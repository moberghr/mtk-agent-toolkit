---
description: Schema for structured learnings stored at .mtk/learnings.jsonl — the machine-readable mirror of tasks/lessons.md
globs: [".mtk/learnings.jsonl", "tasks/lessons.md"]
alwaysApply: false
---

# Structured Learnings Schema

Two-tier model:

- **`tasks/lessons.md`** — committed, team-canonical, human-readable. Source of truth for cross-machine sharing. `learnings.sh regen-markdown` renders **only `scope: "team"` entries** here — `personal` entries stay in the gitignored store and never leak into the committed team file.
- **`.mtk/learnings.jsonl`** — local-only (gitignored), machine-readable JSON Lines (one entry per line), indexed for retrieval. Updated by `correction-capture` / `promote-lesson`. JSONL is used (rather than a single JSON array) so pure-bash tooling can append and grep without an external JSON parser, per S3.3. The store is anchored to the **invoking repo** (git toplevel of the current directory, else cwd), so a plugin-path invocation of `learnings.sh` writes into the caller's repo, never the shared plugin cache.

Manual edits to `tasks/lessons.md` are preserved on next migrate (re-emitted as entries with `source: "manual"`).

## Entry Schema

```json
{
  "id": "L-2026-05-08-001",
  "spec_id": "2026-05-08-v7.5.0",
  "workflow_uuid": "wf-20260508T061101Z-af6eff",
  "scope": "personal | team",
  "source": "correction | promotion | manual | review-finding | incident | golden-path",
  "decision_origin": "user-directed | claude-recommended-approved | claude-recommended-modified | claude-recommended-rejected | system-inferred",
  "captured_at": "2026-05-08T08:42:00Z",

  "files": ["scripts/learnings.sh"],
  "directories": ["scripts/"],
  "phase": "spec | plan | implement | review | postmortem | any",

  "severity": "info | warn | block | incident",
  "memory_type": "episodic | semantic | procedural",
  "supersedes": null,
  "validity": {
    "expires_at": "2027-05-08T00:00:00Z",
    "reconfirmed_at": null,
    "expired": false
  },
  "recurrence": {
    "count": 1,
    "last_seen_at": "2026-05-08T08:42:00Z",
    "related_ids": []
  },

  "title": "Always read tasks/lessons.md size before regenerating",
  "body": "Re-emitting tasks/lessons.md without checking line count tripped the shrink-guard. Compute current size and either pass MTK_SHRINK_GUARD_OVERRIDE=1 with reason or append-only.",
  "rule": "Before regen-markdown, check current line count and use mtk_guarded_write.",
  "applies_when": "phase=implement AND files contain tasks/lessons.md",

  "wrong_turns": [
    "Attempted direct overwrite without checking size — failed shrink-guard on first try.",
    "Tried append-only path but missed the Auto-generated section boundary."
  ],
  "time_cost": 12,
  "evolution_actions": "hook",

  "confidence": "high",
  "output_contract": { "required_files": ["planning_note.md", "summary.json"], "json_fields": ["title", "status"] },
  "prefinal_verification_checklist": [
    { "check_id": "required_files_exist", "description": "Both files exist before finishing.", "verification_method": "file_exists", "blocking": true }
  ],
  "source_evidence_refs": ["evidence:trace-step-002"]
}
```

## Field Notes

- **`id`** — `L-YYYY-MM-DD-NNN`. Monotonic per day. Allocated by `learnings.sh add`.
- **`spec_id`** / **`workflow_uuid`** — at least one MUST be set. If the lesson is captured outside a workflow (manual entry), use `workflow_uuid: "manual"`.
- **`scope`** — `personal` (only loaded by the engineer who captured it) vs `team` (loaded for everyone). `promote-lesson` flips `personal` → `team`.
- **`source`** — provenance:
  - `correction` — engineer redirected the agent mid-session.
  - `promotion` — promoted from personal to team via `promote-lesson`.
  - `manual` — preserved verbatim from `tasks/lessons.md` markdown additions.
  - `review-finding` — a recurring review finding got escalated.
  - `incident` — postmortem-derived lesson.
  - `golden-path` — self-driven struggle-then-success within a session, no engineer correction involved (`golden-path-capture` skill). Distinct from `correction`, which requires an engineer-issued redirect.
- **`decision_origin`** — provenance of the decision that produced this lesson:
  - `user-directed` — engineer dictated the decision.
  - `claude-recommended-approved` — model proposed, engineer accepted unchanged.
  - `claude-recommended-modified` — model proposed, engineer accepted with edits.
  - `claude-recommended-rejected` — model proposed, engineer rejected; lesson captures the rejected path.
  - `system-inferred` — emerged from a deterministic gate or lint, not from a human or model decision.
  Required at emit time — entries missing the field are rejected by `learnings.sh add`. Aggregated by `learnings.sh metrics` into the sycophancy index π = approved / (approved + modified + rejected).
- **`files`** / **`directories`** — used by the proximity layer of retrieval. Either or both may be empty.
- **`phase`** — when this lesson should fire. `any` is valid but discouraged — narrow when possible.
- **`severity`**:
  - `info` — nice-to-know.
  - `warn` — should follow.
  - `block` — must follow; violation should fail review.
  - `incident` — derived from a real incident; outranks all other sources.
- **`memory_type`** *(optional, one of: `episodic` | `semantic` | `procedural`)* — content nature, orthogonal to `source` (which is provenance). `episodic` = a specific session event ("this run tripped the shrink-guard"); `semantic` = an abstracted fact/preference ("the team pins DbContext scoped"); `procedural` = an action pattern/skill ("before regen, check line count"). Improves recall relevance. Absent in pre-v7.22 entries; treated as unset. (Borrow: IAAR-Shanghai/Awesome-AI-Memory content-type taxonomy.)
- **`supersedes`** *(optional string, an entry `id`)* — conflict-driven superseding. When a new lesson contradicts an existing one, capture the new lesson with `supersedes: "<old-id>"` rather than appending a duplicate. `learnings.sh query` derives the superseded set from these forward refs and drops any entry a newer one supersedes — so the old fact stops surfacing without deleting the audit trail. Absent = supersedes nothing. (Borrow: IAAR-Shanghai conflict-driven forgetting.)
- **`validity.expires_at`** — default = `captured_at + 12 months`. Lessons go stale; re-confirm or let them expire.
- **`validity.expired`** — set true after `expires_at` unless `reconfirmed_at` is fresher.
- **`recurrence.count`** — incremented when the same root rule is captured again. ≥3 hits is the trigger to propose `CLAUDE.md` promotion.
- **`wrong_turns`** *(optional array of strings)* — dead ends tried during the session, each with a one-line explanation of why it was wrong. Back-compat: absent in pre-v7.14 entries. `learnings.sh add` accepts the field as pass-through; no parser change needed.
- **`time_cost`** *(optional integer, minutes)* — rough minutes lost due to the absence of this rule. Used by lesson-mining to satisfy admit rule A4. Null when not measurable.
- **`evolution_actions`** *(optional string, one of: `routing` | `claude_md` | `reference` | `hook` | `none`)* — which toolkit asset was updated as a result of this lesson. Forced decision at promote time: `none` is allowed but must be accompanied by a stated reason. Absent in pre-v7.14 entries (treated as `none`).

### Executable lesson contract (optional, v7.25)

These four OPTIONAL fields turn a prose lesson into a *checkable* one — a lesson that carries the shape of a correct outcome and the checks that confirm it, rather than only advice. All are absent by default; a lesson that omits them is fully valid and renders exactly as before. (Borrow: Forsy-AI/agent-apprenticeship `runtime_training` schema.) Deep well-formedness is linted by `mtk-doctor`; `learnings.sh add` stays JSON-parser-free (S3.3) and only guards the outer shape.

- **`confidence`** *(optional string, one of: `low` | `medium` | `high`)* — how trustworthy the contract is. Set at promote time; promotion to a team/authoritative asset should require the path was actually verified (`high`).
- **`output_contract`** *(optional object)* — the shape of a correct result, e.g. `{ "required_files": [...], "json_fields": [...] }`. Caller-authored JSON; `learnings.sh add --output-contract '{...}'` guards that it is a `{...}` object.
- **`prefinal_verification_checklist`** *(optional array of objects)* — blocking/advisory checks to run before declaring the lesson's task done. Each entry: `{ check_id, description, verification_method, blocking }`. `learnings.sh add --prefinal-checklist '[...]'` guards that it is a `[...]` array; `mtk-doctor` verifies each entry carries the required keys.
- **`source_evidence_refs`** *(optional array of strings)* — provenance for the lesson's claims (trace steps, artifacts, review records) — ties a lesson to the evidence that produced it. Set via `--source-evidence-refs "ref1,ref2"`.

## 5-Layer Retrieval Filter

Used by `learnings.sh query` at the start of `spec-driven-development` and `fix`. Returns ranked entries:

| Layer | Test | Effect |
|---|---|---|
| 1. **Proximity** | Any `files` / `directories` overlap with current change manifest? | +30 score |
| 2. **Recurrence** | `recurrence.count >= 2`? | +20 score |
| 3. **Severity** | Map: `incident=40`, `block=25`, `warn=10`, `info=5` | += score |
| 4. **Validity** | `expired == false`? | required, else drop |
| 4b. **Superseded** | Is this entry's `id` in some newer entry's `supersedes`? | required not-superseded, else drop |
| 5. **Phase** | `phase` matches current phase, OR `phase=any`? | required, else drop |

Default: return top 10. Override with `--max N`. Scope filter via `--scope team|personal|all` (default `all`): `team` returns only committed team lessons, `personal` only the engineer's local lessons, `all` both.

## File Layout

```
.mtk/learnings.jsonl     ← JSON Lines: one entry object per line (NOT a single array)
tasks/lessons.md         ← markdown view; `## Auto-generated` (team-scope only) and `## Manual` sections
```

`tasks/lessons.md` structure after migration:

```markdown
# Lessons

<!-- Auto-generated below — managed by scripts/learnings.sh. Edit the "Manual additions" section freely. -->

## Auto-generated (do not edit by hand)

- **L-2026-05-08-001** [block, phase=implement] Always read tasks/lessons.md size before regenerating
  - *Files:* `tasks/lessons.md`
  - *Why:* Re-emitting trips shrink-guard.
  - *Rule:* Before regen, check line count.

## Manual additions (preserved across regen)

<!-- Anything below this marker is read on `learnings.sh migrate` and re-emitted as source="manual" entries. -->
```

## Migration

`learnings.sh migrate` reads existing `tasks/lessons.md`, parses each `## <heading>` block into one entry (title from the heading line, body from the lines beneath it up to the next heading), and emits one JSON entry per block with:

- `source: "manual"`
- `scope: "team"` (since the file was committed)
- `severity: "warn"` (default — engineer can edit later)
- `phase: "any"`
- `expires_at`: `captured_at + 12 months`

Migration is idempotent two ways: (1) once the file carries the auto-generated marker it short-circuits with "Already migrated"; (2) even against a marker-less re-feed, each block's title is hashed (`cksum`) and a block whose hash already exists in the store is skipped — so re-running never duplicates. After ingesting, migrate regenerates the markdown view (`regen-markdown --force`), which is an intentional prose→summary rewrite (full bodies live in the store) and therefore bypasses the shrink-guard.

## Sycophancy Index (π)

`bash scripts/learnings.sh metrics` aggregates `decision_origin` across the last 30 days (configurable via `--window-days`) and emits:

```json
{
  "window_days": 30,
  "totals": {
    "user-directed": 12,
    "claude-recommended-approved": 18,
    "claude-recommended-modified": 6,
    "claude-recommended-rejected": 3,
    "system-inferred": 4
  },
  "pi": 0.667,
  "warn_threshold": 0.70,
  "status": "ok | warn"
}
```

`pi = approved / (approved + modified + rejected)`. Excludes `user-directed` and `system-inferred` (they are not model recommendations). `status: "warn"` when `pi >= warn_threshold`. Threshold tunable via `.claude/review-config.json → sycophancy_index.warn_threshold`. Surfaced by `toolkit-health`.
