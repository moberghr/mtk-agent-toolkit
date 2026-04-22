# Pressure Test — Hooks as Skill Invocation

> Adversarial scenarios for the tier-2 queue primitive, the `UserPromptSubmit`
> dispatcher, and the two Phase 1 triggers (tier-1 correction-nudge,
> tier-2 spec-approval-trigger).
>
> Automated integration tests live under `tests/hooks/`. The scenarios below
> stress behaviours that the shell tests can only partially cover — human
> review sign-off required.

## How To Use These Tests

1. Ensure the working tree is clean (`git status` empty) and `MTK_HOOKS_TIER2=1`.
2. For each scenario, follow the setup steps, perform the action, and compare
   the observed behaviour to **Expected**.
3. Mark each scenario pass/fail in a review notes file. Any fail blocks ship.

---

## Scenario 1 — Casual "no" in a long sentence (false positive)

**Setup:** fresh session, no queued entries, kill-switch on.

**Action:** send the user prompt:

> No, I think the original approach is correct, so let's keep going with the database migration as written.

**Expected:**
- Dispatcher emits **nothing** (no `MTK-NUDGE`, no `MTK-QUEUED`).
- The agreement filter in `prompt-nudges.sh` detects "correct" + "keep going"
  and suppresses the nudge even though the prompt opens with "No,".

**Why it matters:** false-positive corrections erode trust in every subsequent
`MTK-NUDGE` message. Zero tolerance for this class of false positive.

## Scenario 2 — Long session with multiple drains

**Setup:** queue directory populated with 6 fresh entries (TTL not expired),
3 of which share `skill + source_hook` with another (duplicates).

**Action:** send three successive user prompts.

**Expected:**
- First drain: emits exactly 3 unique entries (cap enforced, duplicates collapsed).
- Leftover unique entries remain on disk.
- Second drain: emits remaining unique entries.
- Third drain: empty queue → no output.
- `.claude/queue/` is fully empty afterwards.

**Why it matters:** bounded drain output keeps context injection cost predictable.

## Scenario 3 — Repeat save of already-approved spec

**Setup:** a spec file under `docs/specs/` with `- **Status:** approved`
committed to HEAD. No queue entries present.

**Action:** edit the spec (e.g. fix a typo in another line) via the Edit tool,
triggering `PostToolUse: Edit|Write`.

**Expected:**
- `spec-approval-trigger` runs, reads HEAD, sees `approved` already present,
  exits without writing a queue entry.
- `.claude/queue/` remains empty.
- No `MTK-QUEUED` surfaced on the next prompt.

**Why it matters:** without this guard, every edit of an approved spec would
re-queue planning. Context noise and alert fatigue.

## Scenario 4 — Kill-switch respected

**Setup:** queue pre-populated with a fresh entry. Unset and re-set the
environment:

```bash
export MTK_HOOKS_TIER2=0
```

**Action:**
1. Send a correction-keyword prompt ("no, not like that").
2. Trigger a `spec-approval-trigger` fire (edit a new approved spec).

**Expected:**
- No `MTK-NUDGE` or `MTK-QUEUED` output on the next prompt.
- Queue contents preserved (no drain, no write).

**Re-enable** (`MTK_HOOKS_TIER2=1`) and repeat step 1:
- `MTK-NUDGE` appears in `additionalContext`.

**Why it matters:** opt-out must be absolute. Any leakage breaks the trust
contract that lets engineers disable the feature with confidence.

## Scenario 5 — TTL expiry

**Setup:** write a queue entry by hand with `queued_epoch` 48h in the past
and `ttl_hours: 24`.

**Action:** send any user prompt.

**Expected:**
- Stale entry deleted from disk.
- `queue_expired` counter in `.claude/analytics.json` incremented.
- Dispatcher emits nothing (no other entries pending).

**Why it matters:** stale reminders confuse more than they help. Automatic
cleanup prevents the queue from becoming an unbounded history buffer.

---

## Pass criteria

All five scenarios must pass on a clean tree. Additionally, the automated
tests under `tests/hooks/*.sh` must all return exit 0.
