# Pressure Test: Executable Lesson Contract

These scenarios exercise the optional executable lesson-contract fields
(`confidence`, `output_contract`, `prefinal_verification_checklist`,
`source_evidence_refs`) added to `learnings.sh` and linted by `mtk-doctor`.
The contract turns a prose lesson into a *checkable* one — but it is **optional**,
so the two failure modes to guard are (a) accepting a malformed contract silently
and (b) warning on a legitimate prose lesson that has no contract at all.

## Mechanism check (runnable, no writes to the real store)

```bash
# add --dry-run prints the JSON without touching .mtk/learnings.jsonl.
# Well-formed contract → valid JSON carrying all four fields:
bash scripts/learnings.sh add --dry-run --source golden-path --decision-origin system-inferred \
  --title "Structured note workflow" --confidence high \
  --output-contract '{"required_files":["note.md"],"json_fields":["title","status"]}' \
  --prefinal-checklist '[{"check_id":"files_exist","description":"both exist","verification_method":"file_exists","blocking":true}]' \
  --source-evidence-refs "evidence:step-1" | python3 -m json.tool >/dev/null && echo "PASS: valid contract JSON"

# Prose lesson (no contract flags) → valid JSON, NO contract fields (back-compat):
bash scripts/learnings.sh add --dry-run --source golden-path --decision-origin system-inferred \
  --title "prose only" | grep -qE '"(confidence|output_contract|prefinal_verification_checklist)"' \
  && echo "FAIL: contract leaked" || echo "PASS: prose lesson unchanged"

# Guards reject bad shapes (each must exit 2):
bash scripts/learnings.sh add --dry-run --source golden-path --decision-origin system-inferred --title T --confidence bogus; echo "want exit 2 → $?"
bash scripts/learnings.sh add --dry-run --source golden-path --decision-origin system-inferred --title T --output-contract 'notjson'; echo "want exit 2 → $?"
```

`mtk-doctor` lints the persisted store: a well-formed contract → `PASS lessons`; a
malformed one → `WARN lessons` naming the offending `id` and field; no contracts →
`PASS lessons "no executable lesson contracts to lint"`.

```bash
# Doctor lint (SC5) — saves and restores the real store. Append one well-formed
# and one malformed contract line, run the doctor, read the LESSONS category.
cp .mtk/learnings.jsonl /tmp/ll.bak 2>/dev/null || true
printf '%s\n' '{"id":"L-OK","confidence":"high","output_contract":{"required_files":["a"]},"prefinal_verification_checklist":[{"check_id":"x","blocking":true}]}' >> .mtk/learnings.jsonl
printf '%s\n' '{"id":"L-BAD","confidence":"very-high","prefinal_verification_checklist":[{"description":"no id"}]}' >> .mtk/learnings.jsonl
printf '%s\n' 'this is not json at all' >> .mtk/learnings.jsonl   # unparseable line must not read green
bash scripts/mtk-doctor.sh --json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["checks"]:
    if c["category"] == "lessons": print(c["status"], "--", c.get("detail",""))'
cp /tmp/ll.bak .mtk/learnings.jsonl 2>/dev/null || : > .mtk/learnings.jsonl
```

Expected: `WARN` lines for `L-BAD` (confidence not in enum; checklist[0] missing check_id) and for the unparseable line — never a lone `PASS` over a store that contains a corrupt or malformed entry.

---

## Scenario 1: Malformed checklist entry (missing `check_id`)

**Setup:** A lesson carries `prefinal_verification_checklist: [{"description":"x","blocking":true}]` — no `check_id`.

**Expected behavior:** `mtk-doctor` reports `WARN lessons — <id>: checklist[0] missing check_id`. The malformed entry is surfaced, not silently accepted.

**Failure mode:** Doctor passes the store green, so a checklist that names no check ships as if it were runnable.

---

## Scenario 2: Bad `confidence` value

**Setup:** A lesson has `confidence: "very-high"`.

**Expected behavior:** `learnings.sh add` rejects it at capture (exit 2); if it reaches the store by another path, `mtk-doctor` reports `WARN lessons — <id>: confidence 'very-high' not in low|medium|high`.

**Failure mode:** An out-of-enum confidence is treated as valid, eroding the low/medium/high signal.

---

## Scenario 3: Prose lesson — the check must stay quiet

**Setup:** The store holds only ordinary prose lessons (no contract fields), as every pre-v7.25 lesson does.

**Expected behavior:** `mtk-doctor` reports `PASS lessons "no executable lesson contracts to lint"`. No WARN. The feature is optional; a prose lesson is a complete lesson.

**Failure mode:** Doctor nags that prose lessons "should" have contracts — over-warning that trains engineers to ignore the category.

---

## Scenario 4: "Mark it high confidence so it looks thorough"

**Setup:** A lesson is promoted with `confidence: high` but its golden path was never actually verified (no passing check).

**Expected behavior:** This is a **discipline** failure, not a lint failure — `promote-lesson` reserves `high` for a verified path. The lint checks well-formedness only; the skill and reviewer guard the semantics. The reviewer/engineer should downgrade to `low`/`medium`.

**Failure mode:** Treating `confidence` as decoration — stamping `high` on unverified advice, defeating the point of a contract.

---

## Scenario 5: `output_contract` as a string

**Setup:** A lesson has `output_contract: "must create the files"` (a sentence, not an object).

**Expected behavior:** `learnings.sh add` rejects a non-`{...}` value (exit 2); `mtk-doctor` reports `WARN lessons — <id>: output_contract is not an object`.

**Failure mode:** A prose sentence masquerades as a machine-checkable contract.
