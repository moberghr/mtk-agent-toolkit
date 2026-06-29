---
description: When and how to compress long tool output via scripts/mtk-compress.sh to reclaim context tokens
globs: ["**/*"]
alwaysApply: false
---

# Output Compression

Long Bash output (build logs, test runs, JSON dumps, fetched HTML) burns context budget without proportional information value. `scripts/mtk-compress.sh` is a stdin → stdout filter that compresses output before it lands in context. The PostToolUse hook `hooks/compress-monitor.sh` flags large outputs that did not go through it.

## When to compress

Pipe through `mtk-compress.sh` whenever the command's output is likely above ~5000 chars and most of it is repetition:

- **Build logs** — `dotnet build`, `npm run build`, `tsc`, `cargo build`
- **Test runs** — `dotnet test`, `pytest`, `vitest run`, `jest`
- **Data dumps** — `jq` queries, `cat large.json`, API responses
- **HTML fetches** — `curl https://example.com`
- **Long-running stdout** — migration runs, deployment logs

Skip when:

- Output is short by definition (`ls`, `git status`, `pwd`).
- You need every line preserved (debugging an exact log sequence).
- The output IS the deliverable (you're going to write it to a file unchanged).

## Never compress (safety carve-outs)

Compression elides; some content must survive verbatim. **Never** route the following through the compressor — `lazy ≠ broken`:

- Secrets, tokens, keys, or anything a redaction pass would touch (compressing a leak does not contain it).
- Security / auth findings and the exact lines a reviewer must read.
- Migration plans and destructive-operation output where every step matters.
- Any content destined for an audit trail or compliance record.

These mirror the `code-simplification` safety carve-outs: the same categories that must not be simplified away must not be summarized away. When in doubt, pass the security-relevant slice through uncompressed and compress only the surrounding noise.

## Modes

| Mode | What it does |
|---|---|
| `auto` | Detect by content shape (default) |
| `json` | Parse JSON; truncate arrays > 10 items to head + elision + tail; clip very long strings |
| `logs` | Keep first/last N lines (default 30 each); insert elision marker |
| `tests` | Preserve FAIL / Error / summary lines; collapse runs of PASS noise |
| `html` | Strip `<script>`/`<style>`/comments; collapse whitespace; truncate |

## Recipes

```bash
# Build
dotnet build 2>&1 | bash scripts/mtk-compress.sh logs

# Tests
pytest -v 2>&1   | bash scripts/mtk-compress.sh tests
npm test 2>&1    | bash scripts/mtk-compress.sh tests

# JSON / API dumps
curl -s https://api.example.com/items | bash scripts/mtk-compress.sh json
jq '.' large.json                     | bash scripts/mtk-compress.sh json

# HTML scrape
curl -s https://example.com | bash scripts/mtk-compress.sh html

# Auto-detect (when unsure)
some_command 2>&1 | bash scripts/mtk-compress.sh auto

# Stats — show how much you've saved this session
bash scripts/mtk-compress.sh stats
```

## Knobs

Set in `.claude/settings.local.json` `env` block (per-machine, gitignored):

| Env | Default | Purpose |
|---|---|---|
| `MTK_COMPRESS_MIN_CHARS` | 1000 | Skip compression for inputs shorter than this |
| `MTK_COMPRESS_MAX_LOG_LINES` | 30 | Keep this many head + tail lines in `logs` mode |
| `MTK_COMPRESS_MAX_ARRAY_ITEMS` | 5 | Keep this many head + tail items per JSON array |
| `MTK_COMPRESS_DISABLED` | 0 | If `1`, the compressor passes through unchanged |
| `MTK_COMPRESS_WARN_CHARS` | 5000 | Monitor hook warns above this if output skipped compression |
| `MTK_COMPRESS_MONITOR_DISABLED` | 0 | If `1`, silence the PostToolUse warning |

## Analytics

Each compression run appends one JSON line to `.claude/observability/compression.jsonl`:

```json
{"ts":"2026-05-07T13:30:00Z","session":"abc-123","mode":"tests","in_chars":48000,"out_chars":1800}
```

`bash scripts/mtk-compress.sh stats` summarizes all-time and current-session totals.

## Why it pays off

Build / test commands routinely emit 20–60k chars where 95%+ is identical PASS rows or progress lines. Compressing them to head + elision + tail reclaims thousands of tokens per command without losing the diagnostic signal — failures, summary counts, and timing markers stay intact.
