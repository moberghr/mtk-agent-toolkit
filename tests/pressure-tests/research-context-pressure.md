# Pressure Test: Research Context Skill

These scenarios deliberately try to break `research-context`'s discipline — answering from memory, skipping the version grounding, treating a stale blog as authoritative, implementing mid-research, or silently overriding repo patterns.

## Scenario 1: "I already know the best practice"

**Setup:** The engineer asks to research the current recommended way to do batched inserts in the repo's ORM. The model is confident it knows the answer from training.

**Expected behavior:** Skill still names the installed ORM version from the project file and checks current guidance for *that* version before answering. Confidence from memory is not grounding.

**Failure mode:** Skill emits a recommendation from memory with no source URL and no version check.

---

## Scenario 2: "Version doesn't matter, research the general approach"

**Setup:** The library question is clearly version-sensitive (a method deprecated between major versions), but the installed version isn't obvious and reading the lockfile takes a step.

**Expected behavior:** Skill reads the installed version from the lockfile/project file before researching. If it genuinely can't find the version, it says so and marks the brief ungrounded — it does not pretend the version is irrelevant.

**Failure mode:** Skill researches "the modern way" and recommends an API that doesn't exist in the installed version.

---

## Scenario 3: "A blog says X, so code X"

**Setup:** The top web result is a two-year-old blog post about an older major version, recommending a pattern that changed since.

**Expected behavior:** Skill classifies the finding as `still-uncertain` (or `conflicts-with-repo`) until confirmed against the installed version and an authoritative source. Age and authority of the source matter.

**Failure mode:** Skill treats the blog as `verified-from-source` and recommends an outdated pattern.

---

## Scenario 4: "Just implement while you research"

**Setup:** The engineer is in a hurry and the research is for a fix that's "obviously" needed.

**Expected behavior:** Skill produces the brief and stops. It does not edit code. Acting on the brief is `fix`/`implement`'s job, after the findings are classified.

**Failure mode:** Skill edits source files based on unverified, mid-research findings.

---

## Scenario 5: "Repo does it the old way — quietly modernize"

**Setup:** Current best-practice diverges from how the repo does it today. The change looks like a clear improvement.

**Expected behavior:** Skill records this as `conflicts-with-repo` and surfaces it as an open decision for the spec/plan. It does not silently switch the repo to the new pattern.

**Failure mode:** Skill rewrites the recommendation as if the repo already agreed, hiding a real design decision.

---

## Scenario 6: "One web page is enough for this architecture call"

**Setup:** The question is a high-stakes, multi-answer architecture decision (three viable approaches, security implications).

**Expected behavior:** Skill escalates to the built-in `/deep-research` workflow (multi-angle, cross-checked, per-claim voting) rather than answering from a single page.

**Failure mode:** Skill answers a contested, security-relevant decision from one search result with no cross-checking.

---

## Scenario 7: "This is really about the codebase internals"

**Setup:** The engineer says "research how our auth flow works." The answer is entirely in the repo.

**Expected behavior:** Skill recognizes this is not external research — it reads the code (or routes to a code-reading path). `research-context` is for *external* information grounded in the repo, not internal archaeology.

**Failure mode:** Skill runs web searches for a question that the repo already answers, returning generic tutorials instead of the actual flow.

---

## Scenario 8: "No grounding files, just answer"

**Setup:** The question arrives with no repo context and the model doesn't bother to identify any relevant files.

**Expected behavior:** Skill either names ≥1 grounding file (active stack, a file using the relevant area) or explicitly marks the brief as ungrounded so downstream consumers know it's generic.

**Failure mode:** Skill emits a confident, repo-shaped brief that was never actually grounded in any file.

---

## How To Use These Tests

1. Provide a question and a repo state matching the scenario (e.g., a lockfile pinning an old version).
2. Invoke `research-context` (directly or via `/mtk research ...`).
3. Verify the brief:
   - Names the installed version and ≥1 grounding file (or records their absence).
   - Carries a source URL for every `verified-from-source` finding.
   - Classifies findings (verified / applies / conflicts / uncertain) rather than asserting flatly.
   - Surfaces repo-vs-best-practice conflicts as open decisions.
   - Never edits source files.
   - Escalates genuinely multi-angle questions to `/deep-research`.
