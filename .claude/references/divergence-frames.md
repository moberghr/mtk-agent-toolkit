---
description: Divergence frames for isolated brainstorming mode — 10+ distinct analytical lenses including fintech-specific frames for architecture-shaping decisions
globs: ["**/*"]
alwaysApply: false
---

# Divergence Frames

Frames used by brainstorming's isolated-divergence mode. Each subagent receives exactly one frame and no shared context from peers. The frame is the entire lens through which it must evaluate the decision — it must not adopt other perspectives.

Select 3–5 frames per session. Prefer frames that are maximally distinct in values (what they optimise for) and in stakeholder position (who they represent). The orchestrator's critic pass scores across all frames and must register a trap for any framing where two selected frames would collapse to the same analysis.

---

## Frame Catalogue

### F-REG — Regulator

**Stance.** What must be provable, traceable, and refusable in an audit?

**Optimises for.** Auditability, traceability, reversibility, documented refusals.

**Ask first.**
- Is every state mutation logged with who, what, when, and why?
- Can we produce a full reconstruction of any transaction on demand?
- Can the system refuse a request and prove it refused?
- Are retention and deletion obligations satisfied?

**Trap to register.** This frame tends to maximise record-keeping at the cost of performance and simplicity. Flag any architecture it endorses that would be operationally unacceptable.

---

### F-AUD — Auditor

**Stance.** Where are the gaps between what the system claims and what it actually does?

**Optimises for.** Consistency, evidence integrity, reconciliation.

**Ask first.**
- Do audit logs match the actual database state after each operation?
- Is the audit write in the same transaction as the business write?
- Are there any paths that mutate state without an audit record?
- What would an external auditor find missing?

**Trap to register.** The auditor frame may over-specify logging for internal-only paths. Register if the audit overhead is disproportionate to the exposure.

---

### F-FRD — Fraudster

**Stance.** Given full knowledge of the system design, how would I exploit it?

**Optimises for.** Finding the minimal-cost attack that produces maximum illegitimate gain.

**Ask first.**
- Which inputs are validated client-side only?
- Can I replay a successful request to double-credit my account?
- Are there timing windows between check and act?
- Which service accounts have excess permissions I could abuse?

**Trap to register.** This frame produces high-severity findings but many are impractical in the deployment context. The critic must filter by realistic attacker capability.

---

### F-BOQ — Back Office at Quarter End

**Stance.** What happens to this system when reconciliation runs at 11:58 PM on December 31st?

**Optimises for.** Bulk throughput, idempotency, correctness under load and contention.

**Ask first.**
- Does batch processing degrade gracefully under 10× normal volume?
- Are all operations idempotent so retries do not double-count?
- What locks contend under high-concurrency reconciliation?
- Is the close-of-day process resumable if it crashes mid-run?

**Trap to register.** Optimising for quarter-end throughput can conflict with per-transaction audit requirements. Register if the two frames produce incompatible designs.

---

### F-3AM — 3 AM On-Call

**Stance.** At 3 AM with this system failing, what do I need to diagnose and fix it in under 15 minutes?

**Optimises for.** Observability, diagnosability, safe manual intervention.

**Ask first.**
- Is there a single dashboard that shows system health at a glance?
- Can I safely roll back the last deployment without data loss?
- Are error messages actionable (include the entity id, the operation, the state)?
- Is there a documented runbook for the five most likely failure modes?

**Trap to register.** Operability improvements often add scope. Register any suggestion that adds significant complexity to achieve operability.

---

### F-INV — Inversion

**Stance.** How do I guarantee this fails? Now design to prevent those failures.

**Optimises for.** Robustness by adversarial construction.

**Ask first.**
- What is the simplest input that breaks this?
- Which assumption, if wrong, causes the most damage?
- What happens if the database is unavailable for 30 seconds at the worst moment?
- Which dependency, if it changes its contract, silently breaks us?

**Trap to register.** Inversion generates exhaustive failure scenarios; not all need mitigation. The critic must triage by probability × impact.

---

### F-Z0B — $0 Budget

**Stance.** Implement this with zero new dependencies, zero new infrastructure, and the smallest possible code surface.

**Optimises for.** Simplicity, maintainability, cost.

**Ask first.**
- Can this be solved by a 20-line function instead of a new service?
- Which proposed dependency can be replaced by a stdlib primitive?
- Is the proposed architecture justified by requirements, or by habit?
- What is the minimum viable solution that passes the success criteria?

**Trap to register.** The $0-budget frame may produce solutions that are simple now but expensive to evolve. Register when the proposed simplification trades present cost for future flexibility.

---

### F-RLA — Remove the Load-Bearing Assumption

**Stance.** What assumption is everyone treating as fixed that could be questioned?

**Optimises for.** Novelty, option space, avoiding premature lock-in.

**Ask first.**
- What does the design assume will never change that has changed before?
- Which requirement is stated as a constraint but is actually a preference?
- What would the design look like if the database were replaced with an event log?
- Which integration is treated as stable that is actually owned by a third party?

**Trap to register.** Questioning load-bearing assumptions can produce architectures that are interesting but incompatible with team skills or operational realities. Register when the proposal requires capabilities the team does not have.

---

### F-HCP — Hostile Competitor

**Stance.** If I were building a competing product, which weaknesses of this design would I advertise as my strengths?

**Optimises for.** Market differentiation awareness, user-visible reliability, trust signals.

**Ask first.**
- Which failure modes are visible to end users?
- Where does the system trade user experience for internal convenience?
- Which integration point could a competitor offer with a cleaner contract?
- What would a postmortem look like that goes on the front page?

**Trap to register.** Competitive framing can introduce scope creep toward features not in the current spec. Register if the frame is generating requirements rather than evaluating the proposed design.

---

### F-10Y — 10-Year Maintenance

**Stance.** Who maintains this in 2036, and what do they need?

**Optimises for.** Readability, evolvability, knowledge transfer, low ongoing cost.

**Ask first.**
- Could a new engineer understand the core business rule without asking anyone?
- Are the domain model and the infrastructure cleanly separated?
- Which coupling will be painful to unpick when requirements change?
- Is the schema versioned so migration is possible without downtime?

**Trap to register.** The 10-year frame can over-specify abstraction. Register when proposed layering adds complexity without reducing a concrete future coupling risk.

---

## Orchestrator Critic Scoring Axes

After all subagent outputs are collected, the orchestrator runs the critic pass against these axes:

| Axis | Question |
|---|---|
| **Novelty** | Does this proposal differ meaningfully from the obvious first answer? |
| **Viability** | Could this be implemented by the team within a realistic scope? |
| **Fit** | Does this satisfy the success criteria without violating the spec's out-of-scope list? |
| **Trap register** | What is attractive but broken about this proposal, and why? |

Score each proposal 1–5 on Novelty and Viability; Fit is binary. Cluster proposals by angle (different frames may converge on the same design — collapse duplicates before presenting to the engineer). Deepen the top 2–3 distinct proposals. The trap register is mandatory: every surviving proposal must carry at least one trap entry.
