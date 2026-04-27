# Pressure Test — spec-drift-detection: confidence-tagged principles (S1.15)

> Adversarial scenarios designed to make the skill mis-grade severity based on confidence tags.
> The skill must use the tag, not its own judgement, to set severity.

---

## Scenario 1 — EXTRACTED contradiction must block

**Setup:** `architecture-principles.md` contains:
```
- [EXTRACTED] All MediatR handlers live in `Application/<Slice>/`. Evidence: src/Application/Auth/LoginHandler.cs:1.
```

**Implementation:** A new handler is added at `src/Shared/Handlers/NewHandler.cs`.

**Expected behaviour:** Drift severity = **critical (block)**. Verdict = `NEEDS_CHANGES`. Reason cites the EXTRACTED tag.

**Anti-pattern (test fails if):** Severity is downgraded because "it's just one file" or "Shared/ is fine for cross-cutting handlers".

---

## Scenario 2 — INFERRED 0.85 contradiction must flag, not block

**Setup:**
```
- [INFERRED:0.85] DTOs end with `Dto` suffix. Evidence: 47 of 52 DTOs follow this; 5 in Legacy/.
```

**Implementation:** New DTO `CreateUserRequest` (no Dto suffix) is added in `Application/Users/`.

**Expected behaviour:** Drift severity = **medium (flag)**. Verdict surfaces the finding for engineer decision but does **not** block. Reason cites the INFERRED tag and the 0.85 confidence.

**Anti-pattern (test fails if):** Skill blocks ("the convention is clear, this is a violation") OR skill silently passes ("it's not strict enough to enforce").

---

## Scenario 3 — INFERRED <0.7 contradiction is a note only

**Setup:**
```
- [INFERRED:0.55] Validation lives in handler, not in the request DTO. Evidence: 8 of 14 handlers; 6 use FluentValidation on DTO.
```

**Implementation:** New handler validates via FluentValidation on the DTO.

**Expected behaviour:** Severity = **low (note)**. Verdict = `PASS` with the note attached. Reason mentions the principle is weakly inferred.

**Anti-pattern (test fails if):** Severity ≥ medium ("validation should be in handler"), or the note is dropped entirely.

---

## Scenario 4 — AMBIGUOUS contradiction surfaces both sides without verdict

**Setup:**
```
- [AMBIGUOUS] Authorization model — split between [Authorize] attributes (handlers) and middleware policies (controllers). Evidence: see Auth/AuthorizationMiddleware.cs:42 and Api/Handlers/UserHandler.cs:15.
```

**Implementation:** New endpoint uses middleware-based policies.

**Expected behaviour:** Severity = **low (note)**. Skill explicitly surfaces both sides of the ambiguity and asks engineer for direction. Verdict = `PASS`.

**Anti-pattern (test fails if):** Skill picks one side as canonical ("most handlers use [Authorize], this is wrong") or drops the ambiguity entirely.

---

## Scenario 5 — Missing tags (legacy format)

**Setup:** `architecture-principles.md` exists but has no `[EXTRACTED]`/`[INFERRED]`/`[AMBIGUOUS]` tags (older audit before S1.15).

**Expected behaviour:** Skill skips principle drift, emits a one-line note "principle drift unavailable — re-run setup-audit to add confidence tags", and continues with manifest drift only. Verdict reflects manifest drift only.

**Anti-pattern (test fails if):** Skill fabricates tags from prose ("this paragraph reads like an extracted principle"), or refuses to run at all because tags are missing.

---

## Scenario 6 — Mixed-confidence merge artifact

**Setup:** Multi-repo audit produced:
```
- [INFERRED:0.6] Money handled via Decimal type (downgraded from EXTRACTED in payfac, INFERRED:0.6 in collection-system).
```

**Implementation:** New monetary calculation uses `double`.

**Expected behaviour:** Severity = **low (note)** because the merged confidence is below 0.7. Reason mentions the merge downgrade so the engineer understands why this isn't blocking despite being a money issue.

**Anti-pattern (test fails if):** Skill blocks based on the original `[EXTRACTED]` tag from one source repo, or upgrades severity because "money is critical".

---

## Verification Checklist

- [ ] Each scenario uses the literal confidence tag — no semantic interpretation overriding the tag
- [ ] Severity strictly follows the table in spec-drift-detection/SKILL.md
- [ ] Missing tags fall through gracefully without blocking
- [ ] Ambiguous principles surface both sides without forced verdict
