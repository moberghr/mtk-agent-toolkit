# Pressure Test — mtk doctor

> Adversarial test for `scripts/mtk-doctor.sh`. The doctor must catch deprecated model IDs, version drift, hook mis-registrations, and gitignore gaps without false positives on a clean repo.

## Setup

Run from the MTK repo root.

## Scenarios

### S1 — Clean repo passes

```bash
bash scripts/mtk-doctor.sh
echo "exit=$?"
```

**Pass:** All checks PASS, exit 0, summary shows zero WARN/FAIL.

### S2 — JSON output is valid

```bash
bash scripts/mtk-doctor.sh --json | python3 -m json.tool > /dev/null
echo "json_valid=$?"
```

**Pass:** `python3 -m json.tool` exits 0. Parseable, structured output.

### S3 — Detects deprecated model in agent

```bash
# Setup: temporarily add deprecated model to a test agent
TEST_AGENT=".claude/agents/test-deprecated.md"
cat > "$TEST_AGENT" <<EOF
---
name: test-deprecated
description: test
model: claude-3-opus
---
Test
EOF

bash scripts/mtk-doctor.sh; rc=$?
rm "$TEST_AGENT"

[ "$rc" -ne 0 ] || echo "FAIL: doctor passed despite deprecated model"
```

**Pass:** Doctor reports FAIL with the agent path and `claude-3-opus`. Exit 1.

### S4 — Detects version mismatch

```bash
# Setup: temporarily corrupt plugin.json version
cp .claude-plugin/plugin.json /tmp/plugin.json.bak
sed -i.tmp 's/"version": "[^"]*"/"version": "0.0.0"/' .claude-plugin/plugin.json

bash scripts/mtk-doctor.sh; rc=$?
mv /tmp/plugin.json.bak .claude-plugin/plugin.json

[ "$rc" -ne 0 ] || echo "FAIL: doctor passed on version mismatch"
```

**Pass:** Reports `version mismatch`, exit 1.

### S5 — Detects skill name/dir mismatch

```bash
# Setup: clone a skill with mismatched dir
mkdir -p .claude/skills/test-mismatch
cat > .claude/skills/test-mismatch/SKILL.md <<EOF
---
name: not-test-mismatch
description: test
---
Test
EOF

bash scripts/mtk-doctor.sh; rc=$?
rm -r .claude/skills/test-mismatch

[ "$rc" -ne 0 ] || echo "FAIL: doctor passed on skill name mismatch"
```

**Pass:** Reports `skill name mismatch` with both names. Exit 1.

### S6 — `--fix` adds missing gitignore entry

```bash
cp .gitignore /tmp/gitignore.bak
grep -v '.claude/observability/' /tmp/gitignore.bak > .gitignore

bash scripts/mtk-doctor.sh --fix > /dev/null

grep -q '.claude/observability/' .gitignore && echo "fix_ok"
mv /tmp/gitignore.bak .gitignore
```

**Pass:** `.gitignore` now contains `.claude/observability/`. Doctor reports a PASS for the fix.

### S7 — `--strict` exits non-zero on WARN

```bash
# Use a scenario that produces only a WARN (no FAIL).
# CLAUDE.md over-budget triggers a WARN but not a FAIL.
cp CLAUDE.md /tmp/claude.bak 2>/dev/null || true
yes "padding line" 2>/dev/null | head -250 > CLAUDE.md

bash scripts/mtk-doctor.sh; rc_normal=$?
bash scripts/mtk-doctor.sh --strict; rc_strict=$?

[ -f /tmp/claude.bak ] && mv /tmp/claude.bak CLAUDE.md || rm CLAUDE.md

[ "$rc_normal" -eq 0 ] && [ "$rc_strict" -ne 0 ] || echo "FAIL: --strict didn't fail on WARN"
```

**Pass:** Normal mode exits 0 (only WARN), strict mode exits 1.

### S8 — Detects hook script missing

```bash
# Add a registration for a non-existent hook to a temp settings file.
# (Skip — the doctor reads .claude/settings.json. Modifying it for a test
# is invasive. Verify by code inspection that the loop checks `[ -f "$script" ]`.)
```

**Pass (manual):** Code at `scripts/mtk-doctor.sh` iterates registered hook commands and FAILs on missing scripts.

## Red flags

- False positive on clean repo (any FAIL or WARN when nothing is broken)
- `--fix` modifies source files (skills, agents, manifest) — it must only touch `.gitignore` and file permissions
- New deprecated model added by Anthropic but not in `DEPRECATED_MODELS` array — keep the list current
- Doctor passes when validate-toolkit.sh fails (the integrity category should catch this)
- `--json` produces output that fails `jq .` parsing
