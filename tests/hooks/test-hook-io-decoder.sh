#!/usr/bin/env bash
set -euo pipefail

# Test: the JSON string decoders used by every Edit/Write hook —
#   hooks/lib/hook-io.sh   :: mtk_extract_json_string  (first value of a key)
#   hooks/config-guard.sh  :: extract_json_strings     (every value of a key)
#
# Both decoders used to build their output one character at a time with
# substr(buf, i, 1). On BSD awk every substr call measures the whole buffer, so
# the cost grew with the square of the payload: about 0.7 s at 100 KB, 5.6 s at
# 300 KB and 59 s at 1 MB, against a 5 s hook timeout. A large Write timed the
# hook out and the guards failed open. The decoders now split each input line
# at its backslashes once and print plain runs in one step.
#
# Covers:
#   (a) differential: a verbatim copy of each old decoder (below) is the
#       reference, and old and new must agree on output bytes and exit code
#       over a generated corpus (every escape at the start, middle and end,
#       adjacent escapes, a backslash before the closing quote, unicode escapes
#       and surrogate pairs, raw multi-byte and invalid UTF-8, empty values,
#       the key inside another value, the key twice, nested objects, missing
#       keys, non-string values, truncated payloads, raw line breaks, 50 KB
#       values, and a seeded fuzz set)
#   (b) contract pins that do not depend on the reference
#   (c) timing: 300 KB and 1 MB payloads decode, correctly, within
#       MTK_TEST_DECODER_MAX_SECS (default 2) seconds of CPU time each. CPU
#       time (user + sys of the decoding process tree) is used instead of wall
#       clock so a loaded host does not make the bound flaky; wall clock is
#       printed alongside.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/config-guard.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/hook-io.sh"

echo "=== JSON string decoder test ==="
FAILS=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# config-guard.sh is a hook, not a library: take its separator and its decoder
# out of the file so the test runs exactly the shipped code.
eval "$(grep '^EDIT_SEP=' "$GUARD")"
eval "$(sed -n '/^extract_json_strings() {/,/^}/p' "$GUARD")"
if [ -z "${EDIT_SEP:-}" ] || ! declare -F extract_json_strings >/dev/null; then
  echo "  FAIL  could not load EDIT_SEP and extract_json_strings from $GUARD" >&2
  exit 1
fi

# --- Reference: the decoders as they were before the linear rewrite ----------
# Verbatim apart from the function names. Do not edit these to match a change
# in the shipped decoders: a difference is what this test exists to catch.

ref_extract_json_string() {
  local payload="$1"
  local key="$2"
  local output

  output=$(printf '%s' "$payload" | awk -v key="$key" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if (!match(buf, pattern)) exit 1
      start = RSTART + RLENGTH
      out = ""
      esc = 0
      len = length(buf)
      for (i = start; i <= len; i++) {
        c = substr(buf, i, 1)
        if (esc) {
          if (c == "n") out = out "\n"
          else if (c == "t") out = out "\t"
          else if (c == "r") out = out "\r"
          else if (c == "\"") out = out "\""
          else if (c == "\\") out = out "\\"
          else if (c == "/") out = out "/"
          else if (c == "b") out = out "\b"
          else if (c == "f") out = out "\f"
          else out = out "\\" c
          esc = 0
          continue
        }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") { print out; exit 0 }
        out = out c
      }
      print out
      exit 0
    }
  ') || return 1

  printf '%s\n' "$output"
}

ref_extract_json_strings() {
  printf '%s' "$1" | awk -v key="$2" -v sep="$EDIT_SEP" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      len = length(buf); pos = 1; n = 0
      while (pos <= len && match(substr(buf, pos), pattern)) {
        i = pos + RSTART + RLENGTH - 1
        out = ""; esc = 0
        for (; i <= len; i++) {
          c = substr(buf, i, 1)
          if (esc) {
            if (c == "n") out = out "\n"
            else if (c == "t") out = out "\t"
            else if (c == "r") out = out "\r"
            else if (c == "\"") out = out "\""
            else if (c == "\\") out = out "\\"
            else if (c == "/") out = out "/"
            else if (c == "b") out = out "\b"
            else if (c == "f") out = out "\f"
            else out = out "\\" c
            esc = 0
            continue
          }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") break
          out = out c
        }
        printf "%s%s", (n++ ? "\n" sep "\n" : ""), out
        pos = i + 1
      }
      if (n == 0) exit 1
      printf "\n"
    }
  '
}

# --- (a) Differential over a generated corpus ---------------------------------
CORPUS="$TMP/corpus"
mkdir -p "$CORPUS"
python3 - "$CORPUS" <<'PY'
import json, os, random, sys

out = sys.argv[1]
cases = []

def add(label, payload, key="k"):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    assert b"\0" not in payload
    cases.append((label, key, payload))

def kv(value):
    # The raw JSON text value for key k, between two other members.
    return '{"a":"b","k":' + value + ',"z":"y"}'

# Every escape alone, at the start, at the end and in the middle of a value.
ESC = [r'\"', r'\\', r'\/', r'\b', r'\f', r'\n', r'\r', r'\t', r'\u00e9',
       r'\uD83D\uDE00', r'\x', r'\a', r'\0', r"\'", '\\ ', r'\U', '\\é', '\\😀']
for e in ESC:
    add("escape alone " + e, kv('"' + e + '"'))
    add("escape at start " + e, kv('"' + e + 'abc"'))
    add("escape at end " + e, kv('"abc' + e + '"'))
    add("escape in the middle " + e, kv('"ab' + e + 'cd"'))
# Adjacent escapes.
ADJ = [r'\"', r'\\', r'\/', r'\n', r'\u00e9', r'\x', '\\é']
for a in ADJ:
    for b in ADJ:
        add("adjacent " + a + b, kv('"x' + a + b + 'y"'))
add("adjacent escapes only", kv(r'"\n\t\r\b\f\/\\\""'))

# A backslash before the closing quote.
add("escaped backslash then closing quote", kv(r'"abc\\"'))
add("escaped quote where the close was", '{"k":"abc\\"}')
add("two escaped backslashes", kv(r'"\\\\"'))
add("escaped backslash then escaped quote", kv(r'"\\\""'))
add("three escaped backslashes", kv(r'"\\\\\\"'))

# Unicode escapes and surrogate pairs (kept literal), raw UTF-8, invalid UTF-8.
for v in [r'"\u00e9"', r'"\u00E9x"', r'"\ud83d\ude00"', r'"a\u0000b"', r'"\u12"',
          r'"\u"', r'"pre\ud83dpost"', r'"\\u00e9"', r'"\u005c\u0022"']:
    add("unicode " + v, kv(v))
add("raw UTF-8", kv('"café ☕ 日本語 😀"'))
add("raw UTF-8 keys and value", '{"日本":"x","k":"ü😀","ü":"z"}')
add("escape before a multi-byte character", kv('"x\\😀y\\日"'))
add("invalid UTF-8 bytes", b'{"k":"\xff\xfe\x80abc"}')
add("escape before an invalid byte", b'{"k":"a\\\xffb"}')
add("truncated multi-byte sequence", b'{"\xc3":"x","k":"\xe2\x82"}')

# Empty values.
add("empty value", kv('""'))
add("empty value, compact", '{"k":""}')
add("empty value, spaced", '{"k": ""}')
add("empty value, unterminated object", '{"k":""')

# The key inside another value, twice, and nested objects.
add("key text escaped inside another value", r'{"a":"x \"k\": \"no\"","k":"yes"}')
add("key text after an escaped backslash", r'{"a":"p\\"k":"inner","k":"outer"}')
add("key text in an escaped value only", r'{"a":"\"k\":\"q\""}')
add("raw key text inside a value", '{"note":"the "k":"raw" text","k":"real"}')
add("key twice", '{"k":"first","k":"second"}')
add("key twice, two objects", '{"k":"first"}{"k":"second"}')
add("nested object before the key", '{"o":{"x":{"y":"z"}},"k":"v"}')
add("same key nested first", '{"tool_input":{"k":"inner"},"k":"outer"}')
add("array before the key", '{"arr":[{"a":"b"},{"c":"d"}],"k":"v"}')

# Missing key and non-string values.
for p in ['{"a":"b"}', '{}', '', '"k"', '{"kk":"v"}', '{"xk":"v"}', '{"K":"v"}',
          'k:v', '{"k" "v"}', '{"k"::"v"}']:
    add("missing key " + p, p)
for p in ['{"k":5}', '{"k":null}', '{"k":true}', '{"k":{"a":"b"}}', '{"k":["x"]}',
          '{"k":-1.5e3}', '{"k":1,"o":{"k":"s"}}', '{"k": 5, "k": "later"}']:
    add("non-string value " + p, p)

# Truncated payloads.
for p in ['{"k":"abc', '{"k":"abc\\', r'{"k":"abc\\', '{"k":"', '{"k":', '{"k',
          r'{"k":"abc\u00', '{"k":"a"', r'{"k":"a\"']:
    add("truncated " + p, p)

# Whitespace around the colon.
for p in ['{"k" :  "v"}', '{"k":\n"v"}', '{"k"\t:\t"v"}', '{"k":\r\n "v"}',
          '{"k"\n:\n\n"v"}', '{"k": \f"v"}', '{"k":\v"v"}']:
    add("whitespace " + repr(p), p)

# Raw line breaks (not valid JSON, but the decoder must not change on them).
for p in ['{"k":"a\nb"}', '{"k":"a\\\nb"}', '{"k":"\nabc"}', '{"k":"abc\n"}',
          '{"k":"abc"}\n', '{"k":"abc"}\n\n\n', '{"k":"abc\n', '{"k":"abc\n\n',
          '{"k":"abc\\\n', '{"k":"abc\\\n\n', '\n\n{"k":"v"}', '{"k":"a\n\n\nb"}',
          '{"k":"a\r\nb"}', '{"k":"a\\\r\nb"}', '{"k":"\\\n\\\n"}', '{"k":"\n"}',
          '{"k":"\\\\\nx"}', '{"k":\n"a\\\n\\\\\\\nb"}', '\n', '\n\n',
          '{"a":"x\n","k":"\\\n"}', '{"k":"\\\n\\']:
    add("raw line break " + repr(p), p)

# Escaped trailing line breaks (command substitution drops them).
for v in [r'"abc\n\n"', r'"\n"', r'"\n\n\n"', r'"\r\n"', r'"abc\n\r\n"', r'"a\n\\"']:
    add("escaped trailing line break " + v, kv(v))

# Backslashes only.
for p in ['\\', '\\\\\\\\', r'{"k":"\\\\\\"}', r'{"k":"\\\\\\\"}', '{"k":"\\']:
    add("backslashes only " + repr(p), p)

# Keys as the regex sees them (callers pass plain names; behaviour must not move).
add("regex key k.y", '{"kxy":"v"}', "k.y")
add("regex key file.path", '{"file_path":"/x"}', "file.path")
add("regex key a+", '{"aa":"v","a+":"w"}', "a+")

# Payloads shaped like the harness sends them.
edit = {"session_id": "abc-123", "transcript_path": "/Users/x/.claude/projects/p/abc.jsonl",
        "cwd": "/Users/x/p", "hook_event_name": "PreToolUse", "tool_name": "Edit",
        "tool_input": {"file_path": "/Users/x/p/src/a.ts", "old_string": "const a = \"x\";\n",
                       "new_string": "const a = 'y';\t// \\ path C:\\temp\n"}}
bash_p = {"tool_name": "Bash", "tool_input": {"command": "git commit -m \"fix: x\" && echo 'a\\b'"}}
write = {"tool_name": "Write", "tool_input": {"file_path": "/x/tsconfig.json",
         "content": json.dumps({"compilerOptions": {"strict": True, "note": "a \"q\" \\ b"}}, indent=2)}}
multi = {"tool_name": "MultiEdit", "tool_input": {"file_path": "/x/tsconfig.json", "edits": [
    {"old_string": "a\nb", "new_string": "c\"d"}, {"old_string": "", "new_string": "e\\"},
    {"old_string": "x", "new_string": "y"}]}}
fake = {"edits": [{"old_string": "a", "new_string": "\"new_string\": \"fake\""}, {"new_string": "b"}]}
keys = ["session_id", "transcript_path", "cwd", "hook_event_name", "tool_name", "file_path",
        "old_string", "new_string", "content", "command", "edits"]
for name, obj in [("edit", edit), ("bash", bash_p), ("write", write), ("multiedit", multi), ("fake key", fake)]:
    for style, text in [("compact", json.dumps(obj)), ("indented", json.dumps(obj, indent=2)),
                        ("ascii", json.dumps(obj, ensure_ascii=True)),
                        ("unicode", json.dumps(obj, ensure_ascii=False))]:
        for key in keys:
            add("%s payload, %s, key %s" % (name, style, key), text, key)
ms = json.dumps(multi)
for cut in range(len(ms) - 70, len(ms), 3):
    add("multiedit truncated at %d" % cut, ms[:cut], "new_string")
    add("multiedit truncated at %d" % cut, ms[:cut], "old_string")
add("adjacent occurrences", '"new_string":"a""new_string":"b"', "new_string")
add("adjacent occurrences after an escape", '"new_string":"a\\\\""new_string":"b\\""', "new_string")

# 50 KB values with every kind of content.
rng = random.Random(20261113)
TOKENS = ["plain text ", "\"", "\\", "\n", "\t", "\r", "\b", "\f", "/", "é", "😀", "日本",
          "\x01", "C:\\temp\\x", "\\n", "\"k\": \"v\"", "  ", "{", "}"]
def big(n):
    parts, size = [], 0
    while size < n:
        t = rng.choice(TOKENS)
        parts.append(t)
        size += len(t)
    return "".join(parts)
v1, v2 = big(50000), big(50000)
for ascii_only in (False, True):
    add("50 KB Write, ensure_ascii=%s" % ascii_only,
        json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/x", "content": v1}},
                   ensure_ascii=ascii_only), "content")
    add("50 KB MultiEdit, ensure_ascii=%s" % ascii_only,
        json.dumps({"tool_name": "MultiEdit", "tool_input": {"file_path": "/x", "edits": [
            {"old_string": v1, "new_string": v2}, {"old_string": v2, "new_string": v1}]}},
                   ensure_ascii=ascii_only), "new_string")

# Seeded fuzz over the characters that matter to the decoder.
FUZZ = ["\\", "\\", "\\", "\"", "\"", "n", "u", "t", "r", "/", "b", "f", "a", " ", ":",
        "\n", "\r", "k", "\"k\":\"", "\"k\"", "é", "😀", "0", "{", "}", ",", "\\\\", "\\\""]
def fuzz():
    return "".join(rng.choice(FUZZ) for _ in range(rng.randint(0, 30)))
for i in range(240):
    shape = i % 4
    if shape == 0:
        p = '{"k":"' + fuzz()
    elif shape == 1:
        p = '{"a":"' + fuzz() + '","k":"' + fuzz() + '"}'
    elif shape == 2:
        p = fuzz()
    else:
        p = '{"k":"' + fuzz() + '"' + fuzz()
    add("fuzz %d" % i, p)

for i, (label, key, payload) in enumerate(cases):
    base = os.path.join(out, "%04d" % i)
    with open(base + ".label", "wb") as f:
        f.write(label.encode("utf-8", "backslashreplace"))
    with open(base + ".key", "wb") as f:
        f.write(key.encode("utf-8"))
    with open(base + ".payload", "wb") as f:
        f.write(payload)
PY

DIFF_FAILS=0
CHECKS=0
# differ <label> <reference fn> <new fn> <payload> <key>: same stdout bytes and exit code.
differ() {
  local rc_old=0 rc_new=0
  "$2" "$4" "$5" > "$TMP/old.out" 2>/dev/null || rc_old=$?
  "$3" "$4" "$5" > "$TMP/new.out" 2>/dev/null || rc_new=$?
  CHECKS=$((CHECKS + 1))
  if [ "$rc_old" = "$rc_new" ] && cmp -s "$TMP/old.out" "$TMP/new.out"; then
    return 0
  fi
  DIFF_FAILS=$((DIFF_FAILS + 1))
  printf '  FAIL  %s [%s, key %s]: exit old=%s new=%s\n' "$1" "$3" "$5" "$rc_old" "$rc_new" >&2
  printf '        old: %s\n' "$(head -c 120 "$TMP/old.out" | od -An -c | tr -s ' \n' ' ')" >&2
  printf '        new: %s\n' "$(head -c 120 "$TMP/new.out" | od -An -c | tr -s ' \n' ' ')" >&2
}

CASES=0
for kf in "$CORPUS"/*.key; do
  base="${kf%.key}"
  key="$(cat "$kf")"
  label="$(cat "$base.label")"
  # The x keeps trailing line breaks that command substitution would drop.
  P="$(cat "$base.payload"; printf x)"; P="${P%x}"
  differ "$label" ref_extract_json_string mtk_extract_json_string "$P" "$key"
  differ "$label" ref_extract_json_strings extract_json_strings "$P" "$key"
  CASES=$((CASES + 1))
done

if [ "$CASES" -lt 500 ]; then
  echo "  FAIL  corpus has only $CASES cases; the generator lost some" >&2
  FAILS=$((FAILS + 1))
elif [ "$DIFF_FAILS" -eq 0 ]; then
  echo "  PASS  differential: $CASES payloads, $CHECKS old/new comparisons, output bytes and exit codes identical"
else
  echo "  FAIL  differential: $DIFF_FAILS of $CHECKS comparisons differ" >&2
  FAILS=$((FAILS + DIFF_FAILS))
fi

# --- (b) Contract pins ----------------------------------------------------------
check() { # $1 label  $2 expected  $3 actual
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"
  else
    printf '  FAIL  %s — expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    FAILS=$((FAILS + 1))
  fi
}

rc=0; out="$(mtk_extract_json_string '{"a":"b"}' k)" || rc=$?
check "missing key: exit 1 and no output" "1:" "$rc:$out"
rc=0; out="$(mtk_extract_json_string '{"k":5}' k)" || rc=$?
check "non-string value: exit 1" "1" "$rc"
rc=0; out="$(extract_json_strings '{"a":"b"}' k)" || rc=$?
check "every-occurrence decoder, missing key: exit 1" "1" "$rc"
check "first occurrence wins" "first" "$(mtk_extract_json_string '{"k":"first","k":"second"}' k)"
check "escapes decoded" $'a"b\\c/d\te\nf\rg\bh\fi' \
  "$(mtk_extract_json_string '{"k":"a\"b\\c\/d\te\nf\rg\bh\fi"}' k)"
check "unicode escapes and surrogate pairs kept literal" '\ud83d\ude00 \u00e9 \x' \
  "$(mtk_extract_json_string '{"k":"\ud83d\ude00 \u00e9 \x"}' k)"
check "truncated value prints what it has" "abc" "$(mtk_extract_json_string '{"k":"abc' k)"
# The payload ends in a lone backslash on purpose.
# shellcheck disable=SC1003
check "trailing lone backslash dropped" "abc" "$(mtk_extract_json_string '{"k":"abc\' k)"
check "command substitution drops trailing line breaks" "a" "$(mtk_extract_json_string '{"k":"a\n\n"}' k)"
raw="$(mtk_extract_json_string '{"k":"a\n\n"}' k; printf x)"
check "raw output ends in exactly one line break" $'a\nx' "$raw"
check "every occurrence, EDIT_SEP lines between" "1"$'\n'"$EDIT_SEP"$'\n'"2" \
  "$(extract_json_strings '{"e":[{"k":"1"},{"k":"2\n"}]}' k)"

# --- (c) Timing -------------------------------------------------------------------
BOUND="${MTK_TEST_DECODER_MAX_SECS:-2}"
python3 - "$TMP" "$EDIT_SEP" <<'PY'
import json, os, sys
tmp, sep = sys.argv[1], sys.argv[2]
line = '  "compilerOptions": { "path": "C:\\\\src\\\\x", "msg": "caf\u00e9 \u2713 tab\there" }, // line\n'
def content(n):
    s = (line * (n // len(line) + 1))[:n]
    return s.rstrip("\n") + "x"
def write(name, payload, expected):
    with open(os.path.join(tmp, name + ".json"), "w", encoding="utf-8") as f:
        f.write(payload)
    with open(os.path.join(tmp, name + ".expected"), "w", encoding="utf-8") as f:
        f.write(expected)
for label, n in (("300k", 300000), ("1m", 1000000)):
    c = content(n)
    write("write-" + label, json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/x", "content": c}},
                                       ensure_ascii=False), c + "\n")
    a, b = c[: n // 2], c[n // 2:]
    write("multi-" + label, json.dumps({"tool_name": "MultiEdit", "tool_input": {"file_path": "/x", "edits": [
        {"old_string": "o", "new_string": a}, {"old_string": "p", "new_string": b}]}}, ensure_ascii=False),
        a + "\n" + sep + "\n" + b + "\n")
# Worst case for the piece count: a value made of escapes only.
d = "\\\"\n" * 50000 + "x"
write("dense-300k", json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/x", "content": d}}), d + "\n")
PY

# time_decoder <label> <fn> <name> <key>: decode $TMP/<name>.json in a child
# bash and print "exit cpu wall" from the child's resource usage.
time_decoder() {
  python3 - "$REPO_ROOT/hooks/lib/hook-io.sh" "$GUARD" "$2" "$TMP/$3.json" "$4" "$TMP/timed.out" <<'PY'
import resource, subprocess, sys, time
lib, guard, fn, payload, key, out = sys.argv[1:7]
script = r'''
set -euo pipefail
. "$1"
eval "$(grep '^EDIT_SEP=' "$2")"
eval "$(sed -n '/^extract_json_strings() {/,/^}/p' "$2")"
P="$(cat "$4")"
"$3" "$P" "$5"
'''
r0, t0 = resource.getrusage(resource.RUSAGE_CHILDREN), time.time()
with open(out, "wb") as f:
    rc = subprocess.run(["bash", "-c", script, "_", lib, guard, fn, payload, key], stdout=f).returncode
t1, r1 = time.time(), resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
print("%d %.2f %.2f" % (rc, cpu, t1 - t0))
PY
}

for spec in "mtk_extract_json_string write-300k content" \
            "mtk_extract_json_string write-1m content" \
            "extract_json_strings multi-300k new_string" \
            "extract_json_strings multi-1m new_string" \
            "mtk_extract_json_string dense-300k content"; do
  # shellcheck disable=SC2086
  set -- $spec
  size="$(wc -c < "$TMP/$2.json" | tr -d ' ')"
  read -r rc cpu wall <<<"$(time_decoder "$2" "$1" "$2" "$3")"
  label="$1 on $2 ($size bytes): cpu ${cpu}s, wall ${wall}s, bound ${BOUND}s cpu"
  if [ "$rc" != 0 ]; then
    printf '  FAIL  %s — exit %s\n' "$label" "$rc" >&2; FAILS=$((FAILS + 1))
  elif ! cmp -s "$TMP/timed.out" "$TMP/$2.expected"; then
    printf '  FAIL  %s — decoded output differs from the expected value\n' "$label" >&2; FAILS=$((FAILS + 1))
  elif ! awk -v c="$cpu" -v b="$BOUND" 'BEGIN { exit !(c + 0 < b + 0) }'; then
    printf '  FAIL  %s — over the bound\n' "$label" >&2; FAILS=$((FAILS + 1))
  else
    echo "  PASS  $label"
  fi
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== JSON string decoder: ALL PASS ==="
else
  echo "=== JSON string decoder: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
