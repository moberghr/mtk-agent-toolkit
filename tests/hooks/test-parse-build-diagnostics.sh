#!/usr/bin/env bash
# test-parse-build-diagnostics.sh — verifies hooks/parse-build-diagnostics.sh
# runs on stock /bin/bash 3.2 (no `declare -A`) and that the severity lookup
# still resolves against hooks/analyzer-severity/<stack>.txt.
#
# Runs the target under BOTH `bash` and explicitly `/bin/bash`, asserts real
# JSON output, and asserts the two runs are byte-identical. All scratch state
# lives under mktemp; the repo is only read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/hooks/parse-build-diagnostics.sh"

echo "=== parse-build-diagnostics Test (bash 3.2 portability) ==="
[ -f "$TARGET" ] || { echo "  FAIL  script not found: $TARGET" >&2; exit 1; }

declare -a FAILS=()

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# msbuild input: CA1848 is mapped to `suggestion` in dotnet.txt; CA9999 is
# unmapped (must default to `warning`); the error line must force `critical`.
INPUT_FILE="$TMP/build.txt"
cat > "$INPUT_FILE" <<'EOF'
Program.cs(10,5): warning CA1848: Use LoggerMessage delegates [MyProj.csproj]
Service.cs(22,9): warning CA9999: Some unmapped rule [MyProj.csproj]
Repo.cs(3,1): error CS1002: ; expected [MyProj.csproj]
EOF

run_under() {
  local sh="$1"
  "$sh" "$TARGET" --format msbuild --stack dotnet --file "$INPUT_FILE"
}

OUT_BASH="$(run_under bash)"
OUT_BIN="$(/bin/bash "$TARGET" --format msbuild --stack dotnet --file "$INPUT_FILE")"

# 1) /bin/bash 3.2 must not die on `declare -A` — output must be non-empty JSON.
if printf '%s' "$OUT_BIN" | python3 -m json.tool >/dev/null 2>&1; then
  echo "  PASS  /bin/bash 3.2 produced valid JSON (no declare -A crash)"
else
  FAILS+=("/bin/bash output was not valid JSON: $OUT_BIN")
fi

# 2) The two shells must agree byte-for-byte.
if [ "$OUT_BASH" = "$OUT_BIN" ]; then
  echo "  PASS  bash and /bin/bash output byte-identical"
else
  FAILS+=("bash vs /bin/bash output differ")
fi

# 3) Severity mapping: CA1848 -> suggestion, CA9999 -> warning, error -> critical.
sev_mapped="$(printf '%s' "$OUT_BIN" | python3 -c '
import json,sys
d=json.load(sys.stdin)
m={f["rule"]:f["severity"] for f in d["findings"]}
print(m.get("CA1848",""))
print(m.get("CA9999",""))
print(m.get("CS1002",""))
')"
mapped_1848="$(printf '%s\n' "$sev_mapped" | sed -n 1p)"
mapped_9999="$(printf '%s\n' "$sev_mapped" | sed -n 2p)"
mapped_err="$(printf '%s\n' "$sev_mapped" | sed -n 3p)"

if [ "$mapped_1848" = "suggestion" ]; then
  echo "  PASS  CA1848 resolved to 'suggestion' from dotnet.txt"
else
  FAILS+=("expected CA1848=suggestion, got '$mapped_1848'. JSON: $OUT_BIN")
fi
if [ "$mapped_9999" = "warning" ]; then
  echo "  PASS  unmapped CA9999 defaulted to 'warning'"
else
  FAILS+=("expected CA9999=warning, got '$mapped_9999'. JSON: $OUT_BIN")
fi
if [ "$mapped_err" = "critical" ]; then
  echo "  PASS  error line forced 'critical'"
else
  FAILS+=("expected CS1002=critical, got '$mapped_err'. JSON: $OUT_BIN")
fi

# 4) Empty input -> {"findings":[]} on 3.2.
empty_out="$(printf '' | /bin/bash "$TARGET" --stack dotnet)"
if printf '%s' "$empty_out" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)=={"findings":[]} else 1)'; then
  echo "  PASS  empty input -> {\"findings\":[]}"
else
  FAILS+=("expected empty input to yield {\"findings\":[]}, got '$empty_out'")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — parse-build-diagnostics runs on bash 3.2 with severity lookup intact"
