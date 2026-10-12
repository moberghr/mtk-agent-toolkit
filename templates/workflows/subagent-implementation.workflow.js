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
//   - Dependent batches run SEQUENTIALLY. Batches whose `depends` arrays prove
//     them mutually independent form a WAVE and run concurrently (width capped
//     by args.waveMax / MTK_BATCH_WAVE_MAX, default 3).
//   - Every result carries ts_dispatched / ts_returned so the orchestrator can
//     replay agent_dispatched / agent_returned onto the workflow artifact
//     (`workflow-artifact.sh event … --ts`) — the receipt's per-batch timing
//     depends on them.
//   - Each agent() returns a structured batch result validated against
//     BATCH_RESULT_SCHEMA — the orchestrator judges scope/drift on these.

export const meta = {
  name: 'subagent-implementation',
  description: 'Run planned implementation batches as isolated subagents, in dependency order',
  phases: [{ title: 'Implement', detail: 'one implementer subagent per batch' }],
}

// ---- Filled in by the orchestrator from docs/specs/<date>-<slug>.json --------
// Each batch: { id, prompt, depends: [ids...], wave? }
// `wave` is optional: when absent it is derived from `depends` below (topological
// level), so the plan's dependency list is the single source of truth.
// `prompt` is the shared "Implementer prompt template"
// (.claude/references/subagent-implementer-prompt.md) rendered for this batch
// (repo root, CLAUDE.md, tech stack skill path, the single batch object, spec
// excerpt, full change_manifest, out_of_scope, prior-batch summaries).
const BATCHES = args?.batches ?? []
const MODEL = args?.model ?? undefined // 'sonnet' | 'opus' | undefined (inherit)
const WAVE_MAX = Math.max(1, Number(args?.waveMax ?? 3)) // MTK_BATCH_WAVE_MAX

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

// A rejected agent() call (spend/rate limit, model unavailable, harness kill)
// must not abort the script and lose the other batches' results. It comes back
// as a `killed` marker — outside BATCH_RESULT_SCHEMA on purpose — so the
// orchestrator runs killed-mid-batch recovery for that one batch and records
// it in results.dispatch_incidents[]. `killed` is not `inconclusive`: the
// implementer's partial work is already on disk.
const runBatch = async (b) => {
  const ts_dispatched = new Date().toISOString()
  try {
    const r = await agent(b.prompt, {
      label: `batch:${b.id}`,
      phase: 'Implement',
      model: MODEL,
      schema: BATCH_RESULT_SCHEMA,
    })
    // Timing rides outside the validated schema; the orchestrator replays it.
    return { ...r, ts_dispatched, ts_returned: new Date().toISOString(), model: MODEL ?? 'inherit' }
  } catch (err) {
    return {
      batch_id: b.id,
      status: 'killed',
      model: MODEL ?? 'inherit',
      ts_dispatched,
      ts_killed: new Date().toISOString(),
      error: String(err?.message ?? err),
    }
  }
}

phase('Implement')

// Group batches into waves. Same `wave` number = proven-independent → run
// concurrently. Different waves run strictly in order.
//
// If the orchestrator did not assign `wave`, derive it from `depends`: a batch's
// level is 1 + the max level of the batches it depends on (0 when it depends on
// nothing). Batches at the same level share no ordering edge, so they may run
// together — the planning skill guarantees that two batches touching the same
// file always carry an edge. A level wider than WAVE_MAX is split into chunks
// so one run cannot fan out past the org's concurrency/spend guard.
const byId = new Map(BATCHES.map((b) => [b.id, b]))
const level = new Map()
const levelOf = (b, seen = new Set()) => {
  if (level.has(b.id)) return level.get(b.id)
  if (seen.has(b.id)) throw new Error(`dependency cycle through batch ${b.id}`)
  seen.add(b.id)
  let l = 0
  for (const dep of b.depends ?? []) {
    const d = byId.get(dep)
    if (!d) throw new Error(`batch ${b.id} depends on unknown batch ${dep}`)
    l = Math.max(l, levelOf(d, seen) + 1)
  }
  level.set(b.id, l)
  return l
}
const explicit = BATCHES.every((b) => Number.isInteger(b.wave))
const grouped = []
for (const b of BATCHES) {
  const w = explicit ? b.wave : levelOf(b)
  ;(grouped[w] ??= []).push(b)
}
const waves = []
for (const g of grouped) {
  if (!g) continue
  for (let i = 0; i < g.length; i += WAVE_MAX) waves.push(g.slice(i, i + WAVE_MAX))
}
log(`Schedule: ${waves.length} wave(s) — ${waves.map((w) => w.map((b) => b.id).join('+')).join(' → ')}`)

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
