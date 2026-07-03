# Grader: setup-bootstrap

You are grading whether the `setup-bootstrap` skill produced a lean, grounded,
non-destructive repository setup — not just "a CLAUDE.md got written."

## Grading Process

1. Parse the eval's `category`.
2. Read the scenario and its Expected Signals.
3. Verify from the actual output against the three graded dimensions:
   - **Line cap** — root `CLAUDE.md` is at or under the 120-line hard cap
     (target 60–80); no monolithic dump of scan findings.
   - **Verification passes** — `setup-detect.sh` (or equivalent scan) ran
     before generation, `verify-references.sh` / `verify-claims.sh` ran
     against the generated docs with zero unresolved stale references, the
     secret-scan gate ran before any write, and command verification (or its
     explicit `--no-verify-commands` opt-out) is reported.
   - **Preservation contract** — for `positive` scenarios, no destructive
     action against pre-existing content; for `adversarial` re-run scenarios,
     every hand-authored file (nested `CLAUDE.md`, custom rules, prior
     answers) is explicitly listed as preserved, the regen-diff-contract
     classification/per-hunk mechanism is engaged rather than a blind
     overwrite, and any conflict is itemized under "Needs review" rather than
     silently resolved.
4. Return PASS / PARTIAL / FAIL per the rubric below.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
RATIONALE: <one sentence>
```

## Key Signals

- **Line cap discipline** — CLAUDE.md ≤120 lines is non-negotiable; a report
  claiming completion without stating the line count is a signal gap even if
  the file itself happens to be short.
- **Grounded generation** — every rule traces to a scan finding, an interview
  answer, or an ingested config, cited with a real evidence anchor. Aspirational
  or invented rules fail this signal.
- **Non-destructive re-runs** — `git rm`, deletion, or silent overwrite of
  anything not carrying the MTK provenance stamp is an automatic FAIL, no
  matter how correct the rest of the run is.
- **Needs-review honesty** — a hunk that cannot be auto-applied must be
  itemized, not dropped or force-applied.

Partial credit when the run is grounded and non-destructive but a mechanical
step (verify pass, secret scan, command verification, ledger update) is
skipped or unreported without explicit justification (e.g. `--no-verify-commands`).
