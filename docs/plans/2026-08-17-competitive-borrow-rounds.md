# Competitive Borrow Rounds — 2026-08-17

Five research→compare→borrow rounds, each producing one stacked PR. Per round:
fresh discovery of ~10 active comparable repos (fan-out research agents, file-level
evidence required), comparison against MTK with "already covered" verdicts, one
borrow implemented and validated. Priorities: performance, correctness, token
savings. Prior-borrow ledger consulted to avoid re-borrowing (waves v7.1–v7.31).

## Round 1 research (2026-08-17)

24 unique repos discovered, top 10 deep-dived (all active within the last week):
affaan-m/ECC, Fission-AI/OpenSpec, modu-ai/moai-adk, GanyuanRan/Aegis,
mksglu/context-mode, Opencode-DCP/opencode-dynamic-context-pruning, nizos/probity,
Edmonds-Commerce-Limited/claude-code-hooks-daemon, Doucs91/hivelore,
EveryInc/compound-engineering-plugin. ~40 mechanisms extracted; verdicts recorded
per mechanism (fills gap / partially covered / already covered).

Discarded after verification: the hooks-daemon per-event dispatcher (Claude Code
runs matching hooks in parallel, so consolidating MTK's ~20 ms bash hooks into one
sequential dispatcher does not improve wall-clock latency; measured PreToolUse
floor 19 ms, slowest hook 57 ms).

## Round 1 — Outcome-aware verification ledger (from nizos/probity)

**Gap:** MTK recorded that a verification command *ran* (`mtk_command_is_verification`
match at PostToolUse → `last_verification_seq`), never whether it *passed*. A pytest
run with 12 failures stamped the ledger as verified, and `verify-completion`
accepted it as fresh evidence for a completion claim — its EVIDENCE regex even
matches `FAILED` output. Probity's rule: gate on the outcome *observed* in the
transcript ("observed failing for the right reason"), not on the command having
been typed.

**Borrow:**
- `mtk_classify_verification_outcome()` in `hooks/lib/hook-io.sh` — classifies a
  verification command's `tool_response` as `pass|fail|unknown` from unambiguous
  runner summary shapes (pytest/jest/vitest counts, dotnet `Build FAILED`/
  `Passed!`/`error CSnnnn`, unittest, ruff/mypy, validate-toolkit). Fail shapes
  win over pass shapes ("2 failed, 10 passed" → fail). Everything ambiguous is
  `unknown`, and `unknown` never blocks — per the toolkit lesson that a gate
  which flakes on innocent output is a gate people learn to skip.
- `context-budget.sh` records `last_verification_status` alongside the existing
  seq/epoch/command fields; the payload is sliced at `"tool_response"` so outcome
  markers in the command text itself cannot classify the run.
- `verify-completion` gains a third GAP branch: strong completion claim + fresh
  verification + `status=fail` → block once ("a verification that ran is not a
  verification that passed"), between the re-arm check and the evidence check.

**Test:** `tests/hooks/test-verification-outcome.sh` — classifier shapes (incl.
XFAIL word-boundary and fail-beats-pass), ledger recording via a real PostToolUse
payload, non-verification commands leaving the column untouched, and the Stop-hook
block/no-block/fail-open triple.

## Round 2 — Verification Economy evidence contract (from modu-ai/moai-adk)

**Gap:** verification output enters context verbatim and is then re-quoted in the
completion banner (double burn). `compress-monitor` nags after the fact;
nothing routes output to disk from the start.

**Borrow:** `.claude/references/verification-evidence-contract.md` (the durable
contract: file-redirect form `cmd > log 2>&1`, exit-code echo, bounded tail-30 into
context, evidence persisted under `.mtk/evidence/<session>/` with the citable path
required in the completion report) + `scripts/mtk-verify-run.sh` (wrapper that
implements the contract atomically: unique log per run, `exit=N` line, bounded tail,
`[full output: <path>]` citation) + wiring into `verification-before-completion`
(new "Evidence economy" section referenced from the workflow) and
`subagent-implementer-prompt.md` (VERIFY step routes through the wrapper, JSON
`evidence` field carries the log path + tail, not the full dump). Also
`verify-completion`'s EVIDENCE regex accepts the wrapper's `exit=N` signature.
Validate-toolkit budget tripwire deferred (S2.6a covers descriptions; the
always-loaded-surface estimate is a candidate for a later round).

**Round 2 research (2026-08-17, fresh sweep — evidence handling + new entrants):**
first-fluke/oh-my-agent (Stop-gate with bounded 2000-char tail, no-exec allowlist,
JSONL gate-event trail), fivetaku/fablize (structured-first outcome extraction:
`exit_code`/`returncode`/`success` fields before text regex; redacted evidence
ledger), basilisk-labs/agentplane (evidence contract as schema — checks[] with
sha256-pinned artifact citations, passed/failed/partial/not_run/waived status
enum), sleeplesshan/token-router (lossless line-slicing: select coordinates,
never rewrite; deterministic error-keyword prefilters), PCIRCLE-AI/toonify-mcp
(`updatedToolOutput` replace-at-source; do-not-compress policy learned from
measurement), u-ichi/compact-plus (semantic PreCompact state capture),
chaseai-yt/crucible (persistent-session adversarial review, VERDICT line
contract), Nanako0129/pilotfish re-verified, zeuikli/output-compress
(deterministic fidelity gate protecting file paths through compression).

Two findings folded into this round's implementation: (1) fablize's
structured-first rule — the classifier now reads `"exit_code"/"returncode"/
"success"` from the tool_response before any text shape; (2) token-router's
lossless error slice — on failure the wrapper emits the first error-keyword
hits with log line numbers ahead of the tail, so diagnostics above the tail
are reachable by coordinate. Deferred to later rounds: agentplane's sha256-
pinned citations + status enum, oh-my-agent's JSONL gate-event trail,
crucible's persistent-session review convergence, toonify's replace-at-source
hook mechanism.

**Test:** `tests/hooks/test-mtk-verify-run.sh` — exit-code fidelity (0 and
non-zero), bounded tail on long output, full output preserved on disk, citation
line format, error-hit slice on failure only, structured-field precedence, and
ledger interop (wrapper invocations register as verification commands).

## Round 3 — Fail-safe merge guards on spec-archive (from Fission-AI/OpenSpec)

**Gap:** `spec-archive.sh` promised "never deletes from the baseline by
inference" but never checked it: a typo'd `delta.removes` entry silently removed
nothing (forever), the merged JSON replaced the baseline unvalidated via a
non-atomic cross-device `mv`, and the JSON mutated before the MD/audit so a
mid-run failure left inconsistent state.

**Borrow (all in `scripts/spec-archive.sh`):** sidecar shape pre-validation;
Guard 1 — unmatched-remove refusal with case/whitespace-folded near-miss
suggestions (OpenSpec's foldRequirementName); Guard 2 — re-validate merged JSON
before any replace; Guard 3 — loss accounting (keys that disappeared must equal
keys explicitly removed, else refuse naming the lost keys — OpenSpec's
unaccounted-content rule, deltaspec's C4 "archive without loss"); all-or-nothing
commit point (same-directory temp files, atomic renames, audit appended last);
plus deltaspec's C5 baseline growth advisory (lines/token budget, never blocks).

**Round 3 research (2026-08-17, fresh sweep — artifact integrity + safe writes):**
iuripereira/deltaspec (C4 archive-without-loss CRITICAL gate, C5 token-cost gate
— both folded in), jakubsuplicki/codument (per-symbol fingerprint drift with
proven exemptions; invariant pointers that execute their cited tests;
fingerprint-bound acks that auto-invalidate), claimset/claimset (falsifiability
pre-gate for citations; divergence localization), gastownhall/beads (field-level
three-way automerge naming every superseded cell; typed merge-refusal taxonomy),
AlexZio00/sovereign-skills (validate_memory_claims.py path/provenance checks on
handoff artifacts; handoff attestation receipts), intellectronica/ruler
(provenance-guarded backups; containment/symlink asserts before managed writes),
hyuga611/narai (pre-write "is this still what I last wrote" hash check),
josephbsmith/citationdiff (verification bound to content hash — the
seal-binds-content mechanism), DavidWells/markdown-magic (loss-safe sentinel
block regeneration, write-only-if-changed). Deferred to rounds 4-5: citationdiff
hash-bound approval seals, codument ack invalidation, sovereign-skills handoff
claim validation, ruler containment asserts.

**Test:** `tests/hooks/test-spec-archive-guards.sh` — seed archive, typo'd
remove refused with near-miss, refusal leaves JSON/MD/audit byte-identical and
no temp files, exact remove merges and audits, malformed sidecar refused,
growth advisory fires without blocking. (Its grep assertion also re-learned the
S3.1 lesson: `echo | grep -q` SIGPIPEs under pipefail — case-match instead.)

## Round 4 — Deny ergonomics: every hard deny recovers in one turn

**Gap (hooks-daemon field data):** after a hard deny agents (a) treat the block
as a stop signal and abandon the task, (b) silently lose tool calls batched with
the denied one, or (c) treat one denial as a rule and refuse everything after
(cascade). MTK's ten deny sites each hand-rolled their message; none warned
about batched-sibling cancellation, and only scope-guard named its off-switch.

**Borrow:** `mtk_deny()` in `hooks/lib/hook-io.sh` — every hard deny now carries
a two-line continuation suffix ("this denial applies to THIS call only; batched
calls were CANCELLED — re-issue separately" + "a denial is a correction, not a
stop signal ... earlier denials are past verdicts, not rules" — the anti-cascade
line from probity) and an optional `(disable this guard: …)` footer taught at
the moment of friction. Migrated: security-gate (5 sites, no toggle by design),
interactive-guard (2 heredoc sites, names MTK_INTERACTIVE_GUARD=0), scope-guard
(names the enforce fallback), read-guard (suffix but deliberately NO toggle —
access is human-granted), rule-trigger (reason composed via printf, never an
unquoted heredoc — rule bodies are file content and must not shell-expand).
Reasons are sanitized (control bytes stripped) and capped
(`MTK_DENY_MAX_CHARS`, default 20000) — claude-hud's cap+sanitize rule, since
deny messages echo tool input.

**Round 4 research (2026-08-17, fresh sweep — guard ergonomics + observability):**
Prime-agentai/agent-approval-gate (windowed A-B-A-B loop detector; hook-liveness
heartbeat + "absence of a subagent marker proves nothing"), osteele/
agent-tool-policy (escape hatch as an in-command comment, auditable in the
transcript; deny>ask>allow fixed precedence; per-harness adapters with written
degradation rules), KyongSik-Yoon/baton (deny reasons that steer to delegation;
`"agent_id"` presence as cheap main-vs-subagent discrimination),
nizos/tdd-guard (three-part deny contract: violation + why + imperative next
step; prompt-command guard toggle with attribution),
anode-llc/claude-code-guardrail-hooks (new-violations-only diff guard so
pre-existing debt never deadlocks edits; **claim to verify: under
bypassPermissions an exit-2 deny may not reliably block — only
hookSpecificOutput.permissionDecision "deny"**; one named toggle per guard +
timeout doctrine), abellagonzalo/bash-guard (allow-or-defer-only auto-approver,
structurally cascade-free; defer-reason audit log as tuning corpus),
claude-hud (cap+sanitize transcript-derived display text — folded in),
ccusage (never-silently-zero cost honesty; per-cache-tier attribution),
disler/multi-agent-observability (guard/telemetry sibling-hook split so logging
can never alter a guard's exit code), davila7/claude-code-templates (tiered TTL
cache with dependency invalidation).

**Follow-up items recorded, not implemented:** verify the bypassPermissions
exit-2 claim against a live session before migrating guards to structured
denies; consider baton's `agent_id` discrimination for scope-guard subagent
policy; consider bash-guard's defer-log as tuning corpus for interactive-guard.

**Test:** `tests/hooks/test-deny-ergonomics.sh` — suffix + anti-cascade on
security-gate/interactive-guard/read-guard denies, allowed calls carry no
suffix, toggle hints only where self-service (read-guard must NOT teach one),
sanitize/cap behavior. Also fixed test-interactive-guard case 17, which the
longer message pushed into the S3.1 SIGPIPE flake (`printf | grep -q` under
pipefail → case-match).

## Round 5 — Measured savings attribution (from context-mode + ccusage honesty rules)

**Prior-work check that changed the plan:** the hash-bound-approval-seal
candidate (citationdiff/hashgate) turned out to be **already covered** —
`workflow-artifact.sh cmd_seal/verify-seal` sha256-binds the approved spec+plan
bytes and `spec-approval-trigger.sh` re-queues on stale. MTK's byte-level seal
is stricter than hashgate's canonicalized hash (whitespace edits invalidate —
the accepted tradeoff). `scripts/mtk-savings.sh` also already existed (v7.23).

**The real residual gap:** the savings report only saw `mtk-compress` runs, in
aggregate. Round 2's evidence wrapper knows its *exact measured* savings (full
log bytes on disk vs bytes emitted) and recorded nothing; the report had no
per-source attribution ("which component earns its place" was a vibe, not a
data question); and it printed silent zeros for empty sessions.

**Borrow:**
- `mtk-verify-run.sh` records one measured record per run to the shared
  output-economy ledger (`compression.jsonl`, `mode: "verify-run"`, same schema
  as mtk-compress). Telemetry is fail-open and can never alter the wrapper's
  exit code or output — a broken ledger costs a data point, not a build
  (disler's guard/telemetry split). The emission is composed to a temp file
  first so the byte count is measured, not estimated.
- `mtk-savings.sh` gains a per-source table sorted by measured impact
  (context-mode's per-tool "sorted by impact" presentation) with ccusage's
  never-silently-zero honesty: an unmeasured source is *named as unmeasured*
  (with the command that would measure it), an empty session prints
  "unmeasured", and the summary now states what MTK does NOT measure
  (assistant output tokens, subagent context, prompt-cache effects).

**Round 5 research (2026-08-17, fresh sweep — seals + measured savings):**
Seppelllo/hashgate (versioned canon prefix, fail-closed-with-bounded-blast-
radius hook — seal already covered, canon versioning noted for any future
seal-format change), nradawg/approval-digest (domain-separated digests so a
file hash can never replay as an approval — noted for seal v2),
NORTHTEKDevs/lossless-context-mcp (ceiling/floor/real benchmark triple that
publishes its own NEGATIVE real-world number; "a savings number without a
reconstruction proof is a marketing number"), AbdulrahmanAmer/token-audit
(WORTH_DOING=0.25 refusal-below-payoff; estimates labeled mechanically;
message.id dedup because naive summing double-counts ~2.8x),
bkuan001/halo-record (captured-vs-ingested evidence provenance tiers; fcntl
append lock — not needed here: single-line O_APPEND printf is atomic),
cocaxcode/token-optimizer-mcp (estimation_method tag on every event; sampled
ground-truth calibration), AryanGonsalves/trl-token-reduction (net-of-cost
accounting — charge the preprocessor's own cost against savings),
makinggainz/claude-code-measure-efficiency (the denominator trap: cost/turn
down 22.6% while cost/output-token UP 4.1% — run both denominators),
mnemox-ai/tradememory-protocol (two-level hash chain, idempotent
conflict-detecting append), 2alf/Heimdall (GPL — patterns only: tamper is an
error, never a silent reset).

**Deferred to future waves:** captured-vs-ingested provenance tiers on the
outcome ledger (halo-record); net-of-cost savings accounting and the
denominator-trap methodology note for toolkit-health (trl, makinggainz);
ceiling/floor/negative benchmark fixtures for run-benchmarks (lossless-context);
domain-separated seal digests (approval-digest); estimation_method tags on
analytics events (token-optimizer-mcp).

**Test:** `tests/hooks/test-mtk-verify-run.sh` extended — no ledger and no
crash without `.claude/` (behavior untouched), measured verify-run record
appended with in_chars > out_chars on a 200-line log vs 5-line tail.

## Round 6 — Hook invariants resolved once, not per spawn (2026-08-18)

**Performance — the one axis rounds 1-5 hadn't served.** Profiling (not the
borrow list) located the cost: PreToolUse latency was dominated by re-derived
invariants — `git rev-parse` per `mtk_repo_root()` call (~20ms, ignoring
`$CLAUDE_PROJECT_DIR`), `cksum|cut`+`date` pipelines per `mtk_session_file()`
call (recomputed again inside each lock helper), and rule-trigger's three awk
extractions plus repo-relative resolution on Bash payloads that need only the
command. Fixes: CLAUDE_PROJECT_DIR-first physicalized repo root (memoized,
PWD-keyed; git fallback intact), lock helpers take the precomputed path
(command substitution makes in-function memos invisible to callers),
rule-trigger extracts per tool shape. Measured: rule-trigger 51.8→38.3ms,
PreToolUse wall-clock (slowest parallel hook) 52→39ms (−25%).

**Round 6 research (fresh sweep — performance + lessons lifecycle):**
leeguooooo/claude-code-usage-bar (shared 5s-TTL git-status cache across
consumers — our fix goes further by eliminating the git call; heavy-tick/
light-tick daemon; atomic_write_text discipline), buger/probe (session-scoped
result-dedup cache, content-hash-validated parse cache — candidates for
repomap/setup-audit), RidderH/refinery (typed evidence outcomes where ONLY
repeated_failure counts toward promotion; harness-validated dedup clustering;
fail-closed prune with the "56 files ALL_DEAD, every one wrong — prune never
decides alone" war story), wan-huiyan/memory-hygiene (promotion/demotion
thresholds with a hard cap where promotion past cap requires a demotion;
mechanism-claim integrity lint; feedback lifecycle states). The lessons-
lifecycle material is the strongest deferred pool for a round 7.

**Also fixed (found by running the full 38-file suite):** two more live
SIGPIPE-under-pipefail defects — generate-agents-md's hard-ceiling truncation
died with 141 exactly when the ceiling was needed, and its marker check could
refuse to regenerate its own file; test-query-code-index blamed a different
assertion per run. Third and fourth live catches of the class this cycle →
promoted to rule S3.17 (trigger-delivered when editing hooks/ or scripts/).

## Round 7 — Lesson lifecycle: stale anchors located, retirement human-ruled (2026-08-19)

**Gap:** capture is solved four ways (correction-capture, golden-path-capture,
lesson-mining, promote-lesson) but the stores are append-only and grow forever —
no staleness audit, no consolidation, no retirement path. A lesson citing a file
that no longer exists reads as authority while pointing at nothing.

**Borrow (synthesis of hivelore verifyAnchor + ce-compound-refresh triage +
refinery's prune discipline):**
- `scripts/lesson-anchors.sh` — deterministic stale-anchor check: backtick
  anchors with a live first path segment are existence-checked (path and
  `path:symbol` forms); external example paths are skipped and disclosed, never
  warned about; rename suggestions follow unique-match-or-unresolvable
  (context-kernel's rule) — one candidate suggests, several are named
  ambiguous. WARN-only; `--strict` for CI.
- `lesson-refresh` skill — suggest-only triage Keep/Update/Consolidate/Retire;
  retirement = `> STALE` marking, never deletion; **prune never decides alone**
  (refinery's "56 ALL_DEAD, every one wrong" war story is quoted in the skill);
  due-ness ordering from claude-memory-engine's reverify-after idea.
- `mtk-doctor` integrity WARN when stale anchors exist, pointing at the skill.
- Session lesson captured live in `tasks/lessons.md`: a gate's exit code must
  never travel through a pipe (the round-3 `| tail` incident).

**Round 7 research (fresh sweep — point-of-need recall + newest entrants):**
Arnoldig/claude-memory-engine (mechanical staleness scan nearly identical to
this round's checker — flag-never-delete, three-state field parsing, capped
stale reports; validated the design), pskelton0330/persistent-context-harness
(recall-precision JSONL log — is recall firing, which lessons never surface;
index-health gate with honest DEGRADED), Aditya-Nagariya/harness-forge
(error-signature normalization into a failure ledger; top-3 weighted lesson
injection), vukkt/token-warden (context-rent economics: a lesson must save
more than it costs to carry, SE-based refusal of noisy verdicts; zero-token
contradiction flagging vs CLAUDE.md), Pinperepette/context-kernel (anchored
citation refresh — unique match or unresolvable, folded in),
technomensch/knowledge-graph (enforced point-of-need recall gates per skill
type; recall-miss logging), b2bvic/pretool-memory (thinking-as-query recall
keyed to current reasoning; 30s throttle + content-hash dedup),
sarthakvk/pi-memory (staleness disclaimer injected at recall time),
yiheinchai/rmc (usage-driven compression ladder; answered-vs-unanswered
attribution), viethuynh243/ZeroMem (build-enforced zero-LLM invariant;
abstention gate naming missing terms).

**Round 8 candidate pool (deferred with evidence):** recall-precision logging
on .mtk/learnings.jsonl (pskelton), error-signature failure ledger
(harness-forge), context-rent eviction economics + contradiction flagging
(token-warden), weighted top-N lesson injection (harness-forge), staleness
disclaimer at recall time (pi-memory), thinking-as-query recall trigger
(pretool-memory).

## Round 8 — Full slate: Hermes hardening + the whole option board (2026-08-19)

**Ritual change:** research first, then a decision artifact
(https://claude.ai/code/artifact/c2e0a1f7-7e6a-46f7-af32-202bd986a8ca) with five
options + effort/impact; the engineer chose **build all**. Hermes deep-dive was
explicitly requested: NousResearch/hermes-agent (232k★) disambiguated from the
name collisions, nine implementation files inspected.

**A — Evidence you can't fake** (Hermes verification_evidence.py): exit-status
attributability (`||` masks, `;` requires the verification as last segment,
pipes/backgrounding mask, `&&` attributes exit 0 only, fd redirects clean) gates
the classifier's structured/exit tiers — `pytest || true` no longer stamps the
ledger PASS. Scope column (targeted|full, Hermes _looks_like_target with
runner-path and `./...` exceptions); verify-completion blocks once when a claim
says ALL/fully green over targeted evidence. Test: 8 checks.

**B — Anti-resurrection** (Hermes context_compressor): post-compaction recovery
is framed HISTORICAL SNAPSHOT — latest user message wins, cancel signals close
items, nothing resumes unconfirmed; same preamble in the handoff template.

**C — Read-path token diet** (terse 18k-call field data + Hermes
repetition_guard): MTK_READ_DIET=deny blocks byte-identical re-reads (session-
keyed store, offset/limit exempt, post-compact clears — compaction destroys the
earlier read; measured savings recorded), =advise is envelope-only, default
off. mtk-compress collapses one line repeated >=5x covering >=50% of input.

**D — Rules that prove themselves** (claudemd-prove-it):
scripts/rule-enforcement-map.sh — WIRED/BROKEN/PROSE per numbered rule +
undocumented-hook reverse check, doctor-wired. First live run: 17 wired, 0
broken, 64 prose, **15 undocumented hooks** (genuine drift finding). Building
it re-fixed two of its own bugs live: grep -o token boundary (checksums.sha256
≠ checksums.sh) and hooks/lib/ resolution.

**E — Lesson recall economics** (token-warden + persistent-context-harness):
learnings.sh query logs one JSONL record per query (ids/counts only) to
.mtk/recall-log.jsonl; mtk-savings prints Lesson rent (measured: ~4,781
tok/run total, heaviest lessons named) + recall stats with the
markdown-coverage honesty note; lesson-refresh consults both — data informs,
never decides.

**Bonus — growth gate** (hermes-agent-self-evolution): relative-growth refusal
for machine-proposed rewrites (default 15%), wired into lesson-refresh and
claude-md-capture — suggest-only passes can no longer ratchet always-loaded
context toward the absolute caps.

**Round 8 research trail:** NousResearch/hermes-agent + hermes-agent-self-
evolution (deep-dive with already-covered verdicts: skills_guard ≈ poison-lint,
passive ledger shipped in R1, cache-prefix stability practiced ad hoc — the
enforcement rule remains deferred), alex60217101990/terse (replay regression
corpus + delta-reads deferred), yarrasys/yarramate (git line-range staleness
for lesson anchors deferred), brefledev/claudemd-prove-it,
akovalion/claude-code-test-gates (runner-artifact freshness deferred),
illuwa/ctx-diet (turn-multiplier cost model deferred).

## Cycle summary

Five stacked PRs: #78 outcome-aware verification ledger (correctness), #79
verification evidence contract (tokens), #80 fail-safe spec-archive merge
guards (correctness), #81 deny ergonomics (correctness), #82 measured savings
attribution (tokens). Two live flake catches fixed along the way (both the
S3.1 SIGPIPE class: validate-toolkit reference scan, test-interactive-guard
case 17). ~38 repos researched across 5 fresh sweeps, all borrows backed by
file-level evidence, prior-work-checked against the ledger before building.
