// Reference template for the subagent-implementation DYNAMIC-WORKFLOW PATH.
//
// The orchestrator (the /mtk implement Phase 3 loop) ADAPTS this script: it
// fills in the batch list, the per-batch implementer prompts, and the chosen
// model, then runs it via the Workflow tool. The native runtime shows its own
// plan-approval gate and executes the batches in the background.
//
// CRITICAL CONTRACT (see .claude/skills/subagent-implementation/SKILL.md):
//   - This script replaces ONLY the inner per-batch dispatch loop.
//   - It does NOT do the drift micro-check, sidecar amendment, churn check, or
//     Phase 4 review. Those are orchestrator-side and run AFTER this returns.
//   - Dependent batches run SEQUENTIALLY. Only parallelize a wave when the
//     batches' `depends` arrays prove they are mutually independent.
//   - Each agent() returns a structured batch result validated against
//     BATCH_RESULT_SCHEMA — the orchestrator judges scope/drift on these.

export const meta = {
  name: 'subagent-implementation',
  description: 'Run planned implementation batches as isolated subagents, in dependency order',
  phases: [{ title: 'Implement', detail: 'one implementer subagent per batch' }],
}

// ---- Filled in by the orchestrator from docs/specs/<date>-<slug>.json --------
// Each batch: { id, prompt, depends: [ids...], wave }
// `prompt` is the shared "Implementer prompt template"
// (.claude/references/subagent-implementer-prompt.md) rendered for this batch
// (repo root, CLAUDE.md, tech stack skill path, the single batch object, spec
// excerpt, full change_manifest, out_of_scope, prior-batch summaries).
const BATCHES = args?.batches ?? []
const MODEL = args?.model ?? undefined // 'sonnet' | 'opus' | undefined (inherit)

// Structured result every implementer must return. The runtime validates this
// and retries the agent on mismatch — replacing the manual JSON-parse retry.
const BATCH_RESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['batch_id', 'status', 'actual_files', 'build', 'tests', 'behavioral_diff', 'deviations'],
  properties: {
    batch_id: { type: 'string' },
    // completed = delivered + verified; blocked = build/tests red; inconclusive
    // = returned without runnable evidence. inconclusive is never a pass — the
    // orchestrator respawns it once with narrowed scope, then halts.
    status: { type: 'string', enum: ['completed', 'blocked', 'inconclusive'] },
    actual_files: { type: 'array', items: { type: 'string' } },
    build: {
      type: 'object', additionalProperties: false, required: ['ok', 'evidence'],
      properties: { ok: { type: 'boolean' }, evidence: { type: 'string' } },
    },
    tests: {
      type: 'object', additionalProperties: false, required: ['ok', 'evidence'],
      properties: { ok: { type: 'boolean' }, evidence: { type: 'string' } },
    },
    behavioral_diff: { type: 'string' },
    deviations: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['kind', 'detail', 'justification'],
        properties: {
          kind: { type: 'string' }, detail: { type: 'string' }, justification: { type: 'string' },
        },
      },
    },
  },
}

const runBatch = (b) =>
  agent(b.prompt, {
    label: `batch:${b.id}`,
    phase: 'Implement',
    model: MODEL,
    schema: BATCH_RESULT_SCHEMA,
  })

phase('Implement')

// Group batches into waves. Same `wave` number = proven-independent → run
// concurrently. Different waves run strictly in order. The orchestrator assigns
// wave numbers; the safe default is one batch per wave (fully sequential).
const waves = []
for (const b of BATCHES) {
  const w = b.wave ?? waves.length // default: each batch its own wave
  ;(waves[w] ??= []).push(b)
}

const results = []
for (const wave of waves) {
  if (!wave || wave.length === 0) continue
  if (wave.length === 1) {
    results.push(await runBatch(wave[0]))
  } else {
    // Independent wave — safe to run concurrently (barrier before next wave).
    const waveResults = await parallel(wave.map((b) => () => runBatch(b)))
    results.push(...waveResults)
  }
  // Fail fast: if any batch in this wave failed build/tests, was inconclusive,
  // or died (null), stop scheduling later (dependent) waves. The orchestrator
  // still inspects results on return and respawns inconclusive batches once.
  const broke = results.find(
    (r) => !r || r.status === 'blocked' || r.status === 'inconclusive' || !r.build?.ok || !r.tests?.ok,
  )
  if (broke) {
    log(`Halting: batch ${broke?.batch_id ?? '(null result)'} not completed (status=${broke?.status ?? 'missing'}); later waves skipped.`)
    break
  }
}

// Returned to the orchestrator, which then runs the drift micro-check, sidecar
// persistence, churn check, and Phase 4 review — none of which live here.
return { batch_results: results.filter(Boolean) }
