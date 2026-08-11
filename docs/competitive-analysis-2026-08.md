# Competitive Analysis — August 2026 (30-day sweep)

> Research note. Not a toolkit component; not manifest-listed (same as
> `competitive-analysis-2026-07.md`). Snapshot of what shipped in MTK's domain between
> **2026-07-06 and 2026-08-05**, ranked by popularity × in-domain relevance, with a
> prioritized borrow backlog. Follow-up to the July snapshot — read that one first for
> the enforcement-focused backlog, most of which is now closed.

## Method & scope

Swept GitHub for repos **created after 2026-07-05** touching MTK's job: spec→plan→
implement→review→verify workflow, guardrails, org standards, memory/lessons, repo setup,
skill quality. Filtered ~250 hits down to those with real engineering substance, then
deep-read READMEs, file trees, hooks, and benchmark data with the question: *what can MTK
borrow, and where are we now behind?*

Popularity is reported as **stars/day since creation** — with a 30-day window, absolute
stars flatter older repos, and velocity is the honest signal for "gaining popularity."

---

## The top 10

| # | Repo | Stars | ★/day | Created | What it is |
|---|---|---|---|---|---|
| 1 | `mikehasa/agentacct` | 546 | **45.5** | 07-24 | Agent work + cost accounting from local session logs |
| 2 | `0xwilliamortiz/andrej-karpathy-skills` | 551 | **36.7** | 07-21 | ⚠️ Behavioral guardrails skill — **see safety finding** |
| 3 | `vshulcz/deja-vu` | 543 | **24.7** | 07-14 | Lexical index over 17 harnesses' session logs; recall via MCP |
| 4 | `finna/Finn-loop` | 290 | **20.7** | 07-22 | 3-skill software factory: spec / build / review. Humans merge |
| 5 | `Nanako0129/pilotfish` | 578 | **20.6** | 07-08 | Multi-model orchestration: frontier plans, cheap models execute |
| 6 | `krishagarwal314/CodeJury` | 136 | **11.3** | 07-24 | Knowledge-graph-grounded pipeline + multi-judge review panel |
| 7 | `protect-my-hair/nucleus-marketplace` | 162 | **8.1** | 07-16 | 7-phase workflow, 26 JSON schemas, runtime boundary gates |
| 8 | `T-Zevin/SkillGuardrail` | 145 | **8.1** | 07-18 | Pre-install scanner + guarded installer for Agent Skills |
| 9 | `UiPath/coder_eval` | 108 | **4.0** | 07-09 | YAML eval suites for *your own* skills; CI gate |
| 10 | `cozytab/fable5-mode` | 117 | **3.9** | 07-06 | Five guard hooks: plan gate, model ceiling, evidence-on-close |

**Honorable mentions (low stars, high signal):** `seob717/nunchi` (7★) — the single best
piece of engineering in the sweep, see P0-3. `ajanatka/lean-flow` (0★) — closest
structural twin to MTK. `aaddrick/ticketmill` (13★) — MTK's `batch-fix` as a batch PR
engine. `anshulforyou/grandma` (108★) — markdown memory in your own git.

---

## The through-line: July was enforcement, August is evidence

The July snapshot's theme was *enforcement moves out of the prompt and into deterministic
code*. That fight is over — hooks-as-gates is now assumed, and MTK ships it.

**August's theme is that claims move out of the README and into `benchmarks/`.** Seven of
the ten ship a benchmarks directory with `results.json`, a stated methodology, and — this
is the part that matters — **explicit statements of what the numbers exclude**:

- pilotfish: "36.01% less cost with 7.92% wall-time trade-off," then immediately, "these
  are bounded compatibility and reachability observations, not efficiency claims."
- CodeJury: −75% tokens on a cross-cutting bug, then, "on a very cheap task the fixed gate
  floor costs more than a cold run saves; and on the hardest bug the cheap win shipped a
  narrower fix than the baseline did."
- agentacct: "missing attribution beats wrong attribution: when agentacct cannot prove a
  link, it shows the gap instead of a guess."
- nunchi: 12 real-world CLAUDE.md files, pre-registered harness, and it *publishes its own
  35% micro-recall* — a number that makes the tool look worse, kept because it is true.

MTK ships `benchmarks/fixtures/` containing two diff files and publishes no measured
number anywhere. On the field's new credibility bar, that is our weakest surface — and
it's also the cheapest one to fix, because `scripts/run-benchmarks.sh` already runs
deterministic hook/linter benchmarks. It just doesn't emit or publish anything.

Four secondary convergences:

1. **Session-history mining became a product category.** deja-vu (543★), memmy (570★),
   paxm (437★), emulo (216★), grandma (108★), mentor (72★). All in 30 days.
2. **Model-tier policy is a first-class layer,** not an implementation detail — pilotfish's
   role-based aliases, lean-flow's dispatch lanes, fable5-mode's hard model ceiling.
3. **Ensemble review beat single-reviewer,** with published backing (CodeJury cites a
   four-judge panel at 64.3% human correlation vs 49.6% for the best single judge).
4. **Skill supply-chain security is now its own category** — and finding #2 below shows
   exactly why.

---

## ⚠️ Safety finding: the #2 repo by velocity is not installable as documented

`0xwilliamortiz/andrej-karpathy-skills` — **551 stars, 95 forks, 36.7★/day** — is the
second-fastest-growing repo in the sweep. Verified contents of the entire repository:

```
LICENSE | README.md | README.zh.md | fastsetup.exe | gup.xml | libcurl.dll |
skills/karpathy-guidelines/SKILL.md
```

- The README's **recommended** install is: *"Open fastsetup application and install
  necessary plugins in Claude"*, followed by `/plugin install andrej-karpathy-skills@karpathy-skills`.
- **There is no `.claude-plugin/`, no `plugin.json`, and no `marketplace.json`.** The
  documented plugin-install command cannot resolve against this repo. The only "install"
  the repo actually offers is running the `.exe`.
- `fastsetup.exe` is a **PE32+ Windows GUI binary**. Static inspection identifies it as
  **WinGup** — Notepad++'s "Generic Updater" (`<description>GUP : a free (LGPL) Generic
  Updater</description>`), renamed. It ships with `libcurl.dll` and a `gup.xml` pointing at
  `https://notepad-plus-plus.org/update/getDownloadUrl.php`.
- Both binaries were added via web-UI "Add files via upload" six days *after* the initial
  commit, and re-uploaded on 07-27.

To be precise about what is and isn't proven: the binary appears to be the genuine, signed
Notepad++ updater, not a demonstrated trojan. But a markdown-skill repo whose recommended
install path is running a renamed 800 KB Windows auto-updater — a program whose entire
purpose is to fetch and execute a remote payload — is a supply-chain hazard whether the
intent is malice or careless repackaging. The `.exe` is a swap surface, and 95 forks now
carry it.

This is the **second** consecutive sweep in which the highest-velocity nominal competitor
turned out to be a facade (July's was `felixross66/claude-ai-coding-kit-2026`, an
obfuscated `index.html` with no plugin at all). Two for two is a pattern, not bad luck:
star velocity in this category is trivially purchasable and is anti-correlated with
substance. The actual best engineering in this sweep sits at 7 stars.

**Related, found while running our own checks:** `scripts/poison-lint.sh` fails on this
machine — `line 91: mapfile: command not found`. `mapfile` is a bash 4+ builtin; macOS
ships bash 3.2. Our own supply-chain defense — the P0-5 gap the July analysis identified
and closed — is currently a hard FAIL in `validate-toolkit.sh` on every macOS dev box.
Flagging, not fixing; out of scope for this task.

---

## Head-to-head: where MTK stands

### Where MTK is genuinely ahead

- **Org-standard distribution.** Not one of the ten distributes engineering standards
  across a fleet of repos. `setup-bootstrap` / `--audit` / `--merge` / `setup-converge` /
  `setup-refresh` has no equivalent in the sweep. This remains MTK's moat.
- **Claim verification during setup.** Still unique, as the July analysis found. Every
  competitor generates a CLAUDE.md; none verify the claims in it against the codebase.
- **Adversarial pressure tests.** 20+ files in `tests/pressure-tests/` testing skills
  against *model rationalization*. Nobody else tests this. coder_eval tests whether a skill
  fires; we test whether it can be talked out of firing.
- **Breadth with coherence.** 44 skills / 6 agents / 30 hooks / pluggable tech stacks, with
  a router. The field's toolkits are 3–26 skills with no routing layer.
- **Reason-carrying denies.** `hooks/scope-guard.sh:140` emits a named reason and the
  remedy alongside the exit-2 deny. nunchi *measured* this: a block that withholds its
  reason scored 0/3 on task completion; delivering the reason scored 3/3. We already do the
  right thing here.

### Where MTK is now behind

| Dimension | Field's state | MTK's state |
|---|---|---|
| Published measured results | 7/10 ship `results.json` + honest caveats | `benchmarks/fixtures/` = 2 diffs, nothing published |
| Eval automation | coder_eval: CI gate, `skill_triggered` criterion, min-score floor | Manual by default; **8/44 skills (18%)** have evals |
| Session recall | deja-vu: persistent index, ~1.5 ms search, recall at point of need | `lesson-mining` sweeps transcripts periodically; no index |
| Model-tier policy | Role aliases (pilotfish), hard ceiling (fable5-mode), lanes (lean-flow) | None — `subagent-implementation` has no model policy |
| Review synthesis | CodeJury: corroboration weighting, foreperson, loud abstention | 6 reviewer agents, no merge protocol, no abstention semantics |
| Rule delivery | nunchi: PreToolUse trigger binding, −42.5% start tokens, compaction re-arm | `.claude/rules/INDEX.md` — metadata is there, but instruction-only |

---

## Good / bad / borrow, by repo

**1. agentacct** — *Good:* confidence-labelled attribution (`exact`/`high`/`medium`/`low`)
on every join between token usage and work; refuses to guess. Local-first, read-only,
no API key. *Bad:* 5 MB of docs for a reporting tool; MCP-recording requirement means the
agent must cooperate to be measured. *Borrow:* the confidence label and "show the gap
instead of a guess" rule for `session-analytics.sh` and `toolkit-health`.

**2. karpathy-skills** — *Good:* the 2.5 KB SKILL.md is genuinely well-written and its four
principles overlap MTK's `code-simplification` and `spec-driven-development` almost
exactly. *Bad:* see safety finding. *Borrow:* nothing to install; the content is a
one-page confirmation that our simplicity rules match where the field landed.

**3. deja-vu** — *Good:* lexical-only search (zero LLM, zero embeddings) hits 84.9% hit@1
on LongMemEval-S; redaction at *ingest* time, not search time; incremental `manifest.gob`
watermarks; 200× token reduction vs full history. *Bad:* Go binary + MCP server is a heavy
dependency for a markdown toolkit. *Borrow:* the architecture, not the binary — see P1-5.

**4. Finn-loop** — *Good:* ruthless minimalism. Three skills, 27 KB, one rule — *"If it is
not in the Linear issue, it does not exist."* Explicitly ships without auto-merge, learning
loops, or orchestration, and calls them "next steps." *Bad:* hard Linear dependency; the
review skill has no verification beyond CI checks. *Borrow:* the discipline of a published
staged roadmap. MTK ships 44 skills; a "start here, these three" entry path is missing.

**5. pilotfish** — *Good:* policy written in **role terms, never model names** — `executor`,
`verifier`, `scout` — so policy survives model deprecation. Model aliases over pinned IDs.
Honest benchmarks. *Bad:* the orchestration policy lives in CLAUDE.md prose, and the README
admits "a successful install does not guarantee automatic delegation." *Borrow:* the role
abstraction — see P1-6.

**6. CodeJury** — *Good:* the jury pattern. Parallel judges blind to each other, structured
findings with quoted evidence + severity + confidence, a foreperson that treats
**corroboration as the strongest signal**, a deterministic fallback if the foreperson
fails, and — the best idea in the sweep — *"a judge that errors, times out or returns
garbage abstains and says so. A missing juror must never read as a clean one."* *Bad:*
Python backend + separate service + external code-graph binary. *Borrow:* P1-4.

**7. nucleus** — *Good:* `asset_boundary.py` enforces write permissions at runtime;
`ALERT_AND_BLOCK` with no silent degradation; `result.json` with enum status
(`COMPLETED` / `NEEDS_HUMAN_REVIEW` / `FAILED_BLOCKED`) that downstream tooling can consume.
*Bad:* 26 skills, 7 mandatory phases, 26 JSON schemas. This is the ceremony trap our own
batch-fix dogfooding flagged. *Borrow:* the result enum only (P2-9); leave the schemas.

**8. SkillGuardrail** — *Good:* eight named threat classes, capability *chains*
(sensitive-read + network-egress; decode + execute), never executes anything while
inspecting, resolves remote sources to immutable commits before download, and binds
installs to source commit + package fingerprint so `verify` detects later drift. *Bad:*
scanning is cross-platform but installing is macOS/Linux only. *Borrow:* P2-10.

**9. coder_eval** — *Good:* the answer to "did my skill quietly stop firing?" —
`skill_triggered` is a first-class scored criterion, weighted 0.0–1.0 scoring mixes
deterministic assertions with LLM rubrics, and a scheduled CI job re-validates skills
against the current model. From UiPath, so it has real maintenance behind it. *Bad:*
Docker-centric; heavier than a markdown toolkit needs. *Borrow:* P0-2. This is the single
most directly applicable repo in the sweep.

**10. fable5-mode** — *Good:* five tight hooks, each doing one thing. `fable_spawn_guard`
blocks spawning a subagent on a *stronger* model than the session (hard ceiling, with the
rule that verification must always be ≥ implementer strength). `fable_close_guard` blocks
turn-end unless every closed card carries a `-- evidence:` note. `fable_fail_streak`
injects a debugging "attribution ladder" on every third consecutive failing Bash command.
*Bad:* single-developer, Fable-specific framing, 8 forks. *Borrow:* P1-6, P2-7, P2-8.

---

## Borrow backlog

Priority = value × portability to MTK's markdown/bash/JSON stack.

### P0 — do these

**P0-1. Publish measured numbers.** Extend `scripts/run-benchmarks.sh` to emit
`benchmarks/results.json` (pass rates per hook/linter, timings, corpus size) and surface a
summary in README + `repo-health`. Adopt the field's honesty convention: state what each
number *excludes*. Cheapest credibility win available, and the machinery already exists.
*Source: pilotfish, agentacct, CodeJury, nunchi.*

**P0-2. Close the eval loop.** `validate-toolkit.sh` already prints "Skill-eval coverage:
8 / 44 skills (18%)" and then passes anyway. Adopt coder_eval's model: make
`skill_triggered` a first-class criterion, add a `--min-score` floor, and run a scheduled
CI job so *a skill that quietly stops triggering against a new model surfaces as a failing
criterion*. MTK already has `evals/`, `EVAL_EXECUTOR`, and `EVAL_GRADER` — the loop is
open, not absent. *Source: UiPath/coder_eval.*

**P0-3. Trigger-bound rule delivery.** nunchi compiles CLAUDE.md into
`.claude/rules/*.md` with `trigger.tool` / `trigger.pattern` / `trigger.path` / `strength`
(`block` | `require-read` | `inject`) frontmatter, then a PreToolUse hook reads the *source
document* at the moment the trigger fires. Measured: **−42.5% prompt tokens at session
start** (79,683 → 45,808), 97% reduction in full-document token cost, plus a SessionStart
compaction re-arm so rules summarized away get re-delivered. MTK's `INDEX.md` already
carries `decision` / `topic` / `scope` / `paths` axes and describes exactly this behavior —
as an instruction to the model. One hook converts it to a mechanism. *Source: seob717/nunchi.*

### P1 — high value, moderate effort

**P1-4. Foreperson + abstention for the review lanes.** MTK runs 6 reviewer agents with no
merge protocol. Add: corroboration as the strongest ranking signal, conflicts resolved
toward quoted evidence, low-confidence findings dropped, one verdict — and critically, an
explicit `ABSTAINED` state so a reviewer that errors or times out never reads as a clean
pass. Deterministic fallback if the synthesis step itself fails. *Source: CodeJury.*

**P1-5. Session recall index.** Turn `lesson-mining` from a periodic sweep into a standing
index: incremental per-file watermarks, redaction at ingest, lexical search, recall at
point-of-need instead of on-demand mining. Bash + `grep`/`ripgrep` over a JSONL index gets
most of the value without a Go binary. *Source: vshulcz/deja-vu.*

**P1-6. Model-tier policy layer.** Two mechanisms, both cheap: (a) write agent frontmatter
and skill guidance in **role terms with model family aliases**, never pinned model IDs, so
policy survives deprecation; (b) a PreToolUse spawn guard enforcing that a subagent may not
run on a stronger model than the session, and that **verification is always ≥ implementer
strength**. *Source: pilotfish + fable5-mode.*

### P2 — worth adopting, lower urgency

**P2-7. Evidence-on-close.** `verify-completion` requires cited-command evidence per
completion claim; fable5-mode goes finer — a Stop hook blocking turn-end unless every
checked-off card carries a `-- evidence:` note. Tighten to card granularity.

**P2-8. Attribution ladder on fail streaks.** PostToolUse Bash hook: every third
consecutive failing command, inject the debugging ladder (suspect harness → verify the new
code actually runs → debug product logic → fix via invariant). Advisory, never blocks,
~30 lines. MTK has no equivalent and this is a real failure mode in long sessions.

**P2-9. Machine-readable result package.** Emit `.mtk/workflows/<id>/result.json` with an
enum status (`COMPLETED` / `NEEDS_HUMAN_REVIEW` / `FAILED_BLOCKED`) alongside the markdown
artifacts, so CI and dashboards consume workflow outcomes without parsing prose. *Source:
nucleus.* Take the enum; leave the 26 schemas.

**P2-10. Install-drift verification.** We ship `checksums.sha256` and `poison-lint.sh`. Add
source-commit + fingerprint binding at install and a `mtk-doctor` check that detects drift
from the reviewed version. Given the safety finding above, this protects the team from a
compromised or swapped plugin release. *Source: SkillGuardrail.*

### Explicitly not borrowing

- **nucleus's phase/schema ceremony** (26 schemas, 7 mandatory phases) — our own batch-fix
  dogfooding already flagged ceremony overhead as friction. Adding schema gates would make
  it worse.
- **Finn-loop's tracker coupling** — MTK is tracker-agnostic. Keep it.
- **CodeJury's service architecture** — MTK is a plugin, not a backend.
- **Anything requiring a compiled binary in the install path** — see the safety finding.

---

## Fastest wins

If only three things get done: **P0-1** (publish numbers — hours, and it fixes our weakest
credibility surface), **P0-3** (trigger-bound rules — one hook, and `INDEX.md` already has
the metadata), and **P1-4's abstention semantics** (a reviewer that fails must not read as
a pass — this one is a correctness bug in our review pipeline, not an enhancement).
