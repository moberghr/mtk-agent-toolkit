---
description: When and how to compress long tool output via scripts/mtk-compress.sh to reclaim context tokens
globs: ["**/*"]
alwaysApply: false
---

# Output Compression

`scripts/mtk-compress.sh <mode>` is a stdin → stdout filter for long, repetitive Bash output: build logs, test runs, JSON dumps, fetched HTML. Use it when output is likely above ~5000 chars and mostly noise.

```bash
dotnet build 2>&1 | bash scripts/mtk-compress.sh logs    # head + tail, elision marker
pytest -v 2>&1    | bash scripts/mtk-compress.sh tests   # keeps FAIL/Error/summary, collapses PASS runs
jq '.' big.json   | bash scripts/mtk-compress.sh json    # arrays to head + tail, long strings clipped
curl -s <url>     | bash scripts/mtk-compress.sh html    # strips script/style/comments
some_cmd 2>&1     | bash scripts/mtk-compress.sh auto    # detect by shape
bash scripts/mtk-compress.sh stats                        # savings, from .claude/observability/compression.jsonl
```

Knobs (`.claude/settings.local.json` env): `MTK_COMPRESS_MIN_CHARS` (1000), `MTK_COMPRESS_MAX_LOG_LINES` (30), `MTK_COMPRESS_MAX_ARRAY_ITEMS` (5), `MTK_COMPRESS_DISABLED` (0).

## Do not compress

- **A verification whose result backs a completion claim.** Use `bash scripts/mtk-verify-run.sh -- <cmd>`: a pipe reports the compressor's exit code, and the wrapper keeps the real one plus a citable `.mtk/evidence/` log (`verification-evidence-contract.md`).
- Output you need line-for-line, or that is itself the deliverable.

## Safety carve-outs

Never route these through the compressor. They match the `code-simplification` carve-outs, and they apply to the evidence log too:

- Secrets, tokens, keys, or anything a redaction pass would touch (compressing a leak does not contain it).
- Security / auth findings and the exact lines a reviewer must read.
- Migration plans and destructive-operation output.
- Anything destined for an audit trail or compliance record.

When in doubt, pass the security-relevant slice through uncompressed and compress only the noise around it.
