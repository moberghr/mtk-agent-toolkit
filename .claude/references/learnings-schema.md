---
description: Schema for structured learnings stored at .mtk/learnings.jsonl — the machine-readable mirror of tasks/lessons.md
globs: [".mtk/learnings.jsonl", "tasks/lessons.md"]
alwaysApply: false
---

# Structured Learnings Schema

Borrowed from sanmak/specops (`core/learnings.md`), adapted to MTK's two-tier model:

- **`tasks/lessons.md`** — committed, team-canonical, human-readable. Source of truth for cross-machine sharing.
- **`.mtk/learnings.jsonll`** — local-only (gitignored), machine-readable JSON Lines (one entry per line), indexed for retrieval. Generated from `tasks/lessons.md` and updated by `correction-capture` / `promote-lesson`. JSONL is used (rather than a single JSON array) so pure-bash tooling can append and grep without an external JSON parser, per S3.3.

Manual edits to `tasks/lessons.md` are preserved on next migrate (re-emitted as entries with `source: "manual"`).

## Entry Schema

```json
{
  "id": "L-2026-05-08-001",
  "spec_id": "2026-05-08-v7.5.0-specops-borrows",
  "workflow_uuid": "wf-20260508T061101Z-af6eff",
  "scope": "personal | team",
  "source": "correction | promotion | manual | review-finding | incident",
  "captured_at": "2026-05-08T08:42:00Z",

  "files": ["scripts/learnings.sh"],
  "directories": ["scripts/"],
  "phase": "spec | plan | implement | review | postmortem | any",

  "severity": "info | warn | block | incident",
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
  "applies_when": "phase=implement AND files contain tasks/lessons.md"
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
- **`files`** / **`directories`** — used by the proximity layer of retrieval. Either or both may be empty.
- **`phase`** — when this lesson should fire. `any` is valid but discouraged — narrow when possible.
- **`severity`**:
  - `info` — nice-to-know.
  - `warn` — should follow.
  - `block` — must follow; violation should fail review.
  - `incident` — derived from a real incident; outranks all other sources.
- **`validity.expires_at`** — default = `captured_at + 12 months`. Lessons go stale; re-confirm or let them expire.
- **`validity.expired`** — set true after `expires_at` unless `reconfirmed_at` is fresher.
- **`recurrence.count`** — incremented when the same root rule is captured again. ≥3 hits is the trigger to propose `CLAUDE.md` promotion.

## 5-Layer Retrieval Filter

Used by `learnings.sh query` at the start of `spec-driven-development` and `fix`. Returns ranked entries:

| Layer | Test | Effect |
|---|---|---|
| 1. **Proximity** | Any `files` / `directories` overlap with current change manifest? | +30 score |
| 2. **Recurrence** | `recurrence.count >= 2`? | +20 score |
| 3. **Severity** | Map: `incident=40`, `block=25`, `warn=10`, `info=5` | += score |
| 4. **Validity** | `expired == false`? | required, else drop |
| 5. **Phase** | `phase` matches current phase, OR `phase=any`? | required, else drop |

Default: return top 10. Override with `--max N`. Engineer scope filter: include `personal` only if the entry's `captured_by` (env `MTK_USER` or git config user.email) matches; always include `team`.

## File Layout

```
.mtk/learnings.jsonl      ← single JSON document, top-level array
tasks/lessons.md         ← markdown view; `## Auto-generated` and `## Manual` sections
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

`learnings.sh migrate` reads existing `tasks/lessons.md` (any prior format), parses entries on a best-effort basis (heading or bullet level), and emits one JSON entry per recognizable lesson with:

- `source: "manual"`
- `scope: "team"` (since the file was committed)
- `severity: "warn"` (default — engineer can edit later)
- `phase: "any"`
- `expires_at`: `captured_at + 12 months`

Migration is idempotent. Re-running does not duplicate entries when matched by title hash.
