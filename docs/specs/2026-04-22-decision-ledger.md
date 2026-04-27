# Agent Decision Ledger (Tamper-Evident Audit Trail)

- **Date:** 2026-04-22
- **Slug:** decision-ledger
- **Scope:** new-feature (new subsystem, integrates with existing hooks + skills)
- **Status:** draft

## Summary

Add an **append-only, hash-chained decision ledger** that records every material agent decision during a Claude Code session: skill invocations, spec approvals, reviewer verdicts, correction captures, verification results, scope gate hits, and security-pack runs. Each entry is linked to the previous by SHA-256 hash, so tampering with any historical entry breaks the chain and is detectable.

Strategic differentiator nobody in the Claude ecosystem ships. Produces the SOC 2 / DORA / MiFID II "what did the AI do, under what approval, and can we replay it?" evidence artifact that regulated customers increasingly require. Inspired by LangGraph's checkpointed-state pattern, but expressed as a plugin-native, plaintext-auditable ledger rather than a runtime.

## Success Criteria

| ID | Description | Verification |
|---|---|---|
| SC1 | `.claude/ledger/` exists with `chain.jsonl` (append-only, one JSON object per line, each referencing previous entry's hash). | File exists after first recorded event. |
| SC2 | Every entry has: `seq`, `ts`, `session_id`, `kind`, `actor` (user/agent/hook/skill), `payload`, `prev_hash`, `hash`. `hash = sha256(prev_hash || canonical(payload) || ts || seq)`. | Schema test `tests/ledger/test-entry-shape.sh`. |
| SC3 | Hash chain integrity verifier: `scripts/verify-ledger.sh` walks chain from genesis, recomputes hashes, exits 0 if intact, non-zero with line number of first break. | Integrity test — tamper with one line, verifier catches it. |
| SC4 | The following events are recorded automatically: skill invocation (start + end), spec status change to approved, compliance-reviewer verdict, correction-capture, verification-before-completion result, scope-guard trigger, security-audit run with pack list. | Integration test per event type. |
| SC5 | Ledger recording is behind kill-switch `MTK_LEDGER=1` (default on). `MTK_LEDGER=0` disables all writes; existing workflows unaffected. | Kill-switch test. |
| SC6 | Genesis entry written on first session with ledger enabled in a repo; subsequent sessions append. Session boundaries recorded as `kind: session_start` / `session_end` events. | Multi-session test. |
| SC7 | `scripts/ledger-export.sh <from> <to>` emits a human-readable audit report (markdown) and a machine-readable JSON extract for a date range. | Export test. |
| SC8 | Sensitive payload fields (file contents, prompt bodies) are NOT stored raw; only SHA-256 hashes + short excerpts (≤120 chars). Raw content stored separately under `.claude/ledger/payloads/<hash>.txt` (gitignored). Design keeps chain small and avoids leaking secrets into a file that may be archived long-term. | Audit of payloads — no full prompts in `chain.jsonl`. |
| SC9 | `chain.jsonl` is gitignored by default but can be opted-in to commit via `.claude/ledger/commit.config` — teams choose whether ledger lives in git or in separate append-only storage. | Config file respected. |
| SC10 | `toolkit-health` skill surfaces ledger stats: entries-per-day, chain-intact status, last verified timestamp. | `toolkit-health` output includes ledger block. |
| SC11 | `scripts/validate-toolkit.sh` passes; pressure tests pass. | Green. |

## Architecture

### Ledger format

`chain.jsonl` — newline-delimited JSON, append-only. One line per event.

```json
{
  "seq": 1,
  "ts": "2026-04-22T15:00:00.123Z",
  "session_id": "sess-4a7b...",
  "kind": "skill_invocation_start",
  "actor": "agent",
  "payload": {
    "skill": "security-and-hardening",
    "args_hash": "sha256:…",
    "excerpt": "…first 120 chars…"
  },
  "payload_ref": "sha256:abc123…",
  "prev_hash": "sha256:000…0",
  "hash": "sha256:def456…"
}
```

**Genesis entry** has `seq: 0`, `kind: "genesis"`, `prev_hash: "0"*64`.

### Hash computation

```
canonical = JSON.stringify(payload with sorted keys)
hash = sha256( prev_hash || canonical || ts || str(seq) )
```

Canonical JSON ensures byte-stable serialization. A small helper in `scripts/ledger-hash.sh` using `jq -S` + `shasum -a 256` (macOS default) keeps the dep surface zero.

### Event kinds (v1)

| Kind | Emitter | Triggers on |
|---|---|---|
| `genesis` | first write | Session 1 in a repo |
| `session_start` / `session_end` | SessionStart / Stop hooks | Each session |
| `skill_invocation_start` / `skill_invocation_end` | tier-2 skill-queue hooks + UserPromptSubmit drain | Skill fires |
| `spec_approved` | existing spec-approval-trigger hook | `status: approved` diff |
| `correction_captured` | correction-capture skill | Skill runs |
| `verification_result` | verification-before-completion skill | Skill runs |
| `scope_guard_trigger` | existing scope-guard hook | Hook fires |
| `reviewer_verdict` | compliance-reviewer agent | Agent concludes |
| `security_audit_run` | security-and-hardening skill | With active pack list |

New events added over time — kind list lives in `references/ledger/event-kinds.md`.

### Integration points

1. **Tier-2 hooks already in repo** (`hooks-as-skill-invocation`) gain one line: after queue write, also call `scripts/ledger-append.sh <kind> <payload-json>`.
2. **Hooks.json additions:** `SessionStart` and `Stop` gain ledger-boundary emitters.
3. **Skills** gain a one-liner at end of workflow section: "On completion, emit `verification_result` ledger entry."
4. **compliance-reviewer** agent prompt gains: "On conclusion, write `reviewer_verdict` ledger entry with bracketed citations preserved."

Writes go through `scripts/ledger-append.sh` which:
- Reads last-line hash (or initializes genesis).
- Computes new hash.
- Atomically appends via `>>` with `flock` (macOS: use `shlock` or fallback to `mktemp`+`cat`+`mv` with file lock via `/usr/bin/flock` when available).
- Writes payload body to `payloads/<hash>.txt` if payload exceeds 120 chars.

### Verifier

`scripts/verify-ledger.sh`:

```
line 1: expect genesis, prev_hash = 0…, verify hash
for each subsequent line:
  h = sha256(prev_line.hash || canonical(payload) || ts || seq)
  if h != line.hash -> EXIT 2, report line number
  if line.prev_hash != prev_line.hash -> EXIT 2
PASS
```

Runs in CI or on demand. `toolkit-health` calls it weekly.

### Export

`scripts/ledger-export.sh <from-ISO> <to-ISO> --format {md|json}`:

- Filters by `ts` range.
- For each entry, resolves `payload_ref` if present (inlines payload body).
- Markdown output: one section per session, table per session with kind/actor/ts/excerpt.
- JSON output: array of resolved entries (for downstream audit tooling).

### Secrets hygiene

Never write raw prompts, code bodies, or tool outputs into `chain.jsonl`. Only:
- A ≤120-char excerpt.
- A `payload_ref` hash pointing to `payloads/<hash>.txt` (gitignored by default).

Rationale: chain.jsonl is the auditable artifact; if teams commit it, it must not contain secrets. Payload bodies stay local unless explicitly exported.

## Implementation Batches

| Batch | Files | Verification |
|---|---|---|
| B1 | `scripts/ledger-hash.sh`, `scripts/ledger-append.sh`, `scripts/verify-ledger.sh`. Gitignore `.claude/ledger/payloads/` by default. | Unit tests for hash + append + verify. |
| B2 | `references/ledger/event-kinds.md`, `references/ledger/schema.md`. | Docs exist. |
| B3 | Wire `SessionStart` / `Stop` hooks to emit session boundary events. Kill-switch `MTK_LEDGER`. | SC5, SC6. |
| B4 | Wire tier-2 queue hooks + drain to emit skill invocation events. | SC4 (skill part). |
| B5 | Wire scope-guard, verification, correction-capture, spec-approval, security-audit to ledger. | SC4 (rest). |
| B6 | `compliance-reviewer` agent updated to emit `reviewer_verdict`. | Agent test. |
| B7 | `scripts/ledger-export.sh` + sample export fixtures. | SC7. |
| B8 | `toolkit-health` skill surfaces ledger stats. | SC10. |
| B9 | Pressure test: tamper with historical entry, verify detection. Pressure test: kill-switch. Manifest + validation. | SC3, SC5, SC11. |

## Open Questions

- **Storage location:** in-repo (`.claude/ledger/`) vs dedicated repo vs S3/GCS. **Recommend in-repo + gitignored by default**; teams that need long-term retention rotate to external storage via a `ledger-export` cron. Simpler, local-first, works for solo and team.
- **Clock skew:** `ts` from local clock. Good enough for audit evidence where `seq` + hash are authoritative; timestamps are advisory. Don't over-engineer with NTP checks in v1.
- **Cross-session continuity:** A fresh clone of the repo doesn't have a prior chain. Genesis per-repo is acceptable; cross-clone continuity is a v2 problem (requires shared remote storage).
- **Compatibility with analytics.json:** analytics.json stays for aggregate counters; the ledger is the per-event artifact. Don't merge them.

## Dependencies

- Builds on tier-2 hooks infrastructure (`hooks-as-skill-invocation` — already merged).
- `regulatory-framework-references` + `sarif-and-compliance-packs` benefit from ledger (reviewer_verdict entries cite framework clauses; security_audit_run entries record pack list). Can ship before them but pays off more once those land.

## Out of Scope

- Remote/centralized ledger storage.
- Signed entries (GPG/ed25519) — hash chain gives tamper evidence; identity signing is v2.
- Real-time streaming to SIEM.
- UI for browsing ledger (markdown export is enough for v1).
