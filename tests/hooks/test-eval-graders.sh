#!/usr/bin/env bash
set -euo pipefail

# Regex and tool_used graders of the eval cases, checked against a small corpus of good and
# bad replies (tests/hooks/fixtures/eval-graders/<case>.<grader>.json). Each fixture names
# one grader file and lists samples with the verdict a person would give:
#   text            the reply, or the file content for a file-target grader
#   events          trace events (JSON-encoded one per line, as the eval does) for a trace grader
#   calls           [{tool, input}] for a tool_used grader
#   scaffold_file   the target file from a fresh run of the case's scaffold.sh,
#                   optionally edited with replace: [old, new]
#   missing         the target file does not exist (a file-target grader then fails)
# Patterns run in Node, because the eval runs them as JavaScript regular expressions
# (lookbehind and flag handling differ in other engines). Skipped when node is missing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FX="$SCRIPT_DIR/fixtures/eval-graders"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available" >&2; exit 0; }
[ -d "$FX" ] || { echo "FAIL: fixture directory not found: $FX"; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

RC=0
node - "$REPO_ROOT" "$FX" "$SBX" <<'JS' || RC=$?
const fs = require('fs'), path = require('path'), cp = require('child_process');
const [root, fxDir, sbx] = process.argv.slice(2);

// Frontmatter of a grader file: key: value lines; single-quoted strings use '' for a quote.
function grader(file) {
  const m = fs.readFileSync(file, 'utf8').match(/^---\n([\s\S]*?)\n---/);
  if (!m) throw new Error('no frontmatter in ' + file);
  const fm = {};
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^(\w+):\s*(.*)$/);
    if (!kv) continue;
    let v = kv[2].trim();
    if (v.startsWith("'")) v = v.slice(1, -1).replace(/''/g, "'");
    else if (v.startsWith('{')) {
      const o = {};
      for (const p of v.slice(1, -1).split(',')) { const i = p.indexOf(':'); o[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }
      v = o;
    } else if (/^\d+$/.test(v)) v = Number(v);
    fm[kv[1]] = v;
  }
  return fm;
}

const scaffolds = {};
function scaffoldDir(caseName) {
  if (scaffolds[caseName]) return scaffolds[caseName];
  const dir = path.join(sbx, caseName);
  fs.mkdirSync(dir, { recursive: true });
  cp.execFileSync('bash', [path.join(root, 'evals', caseName, 'scaffold.sh')], { cwd: dir, stdio: 'ignore' });
  return (scaffolds[caseName] = dir);
}

function verdict(g, sample, caseName) {
  if (g.type === 'tool_used') {
    const re = g.input_match ? new RegExp(g.input_match) : null;
    const n = (sample.calls || []).filter(c => c.tool === g.tool && (!re || re.test(JSON.stringify(c.input)))).length;
    return n >= (g.min === undefined ? 1 : g.min) && n <= (g.max === undefined ? Infinity : g.max);
  }
  if (g.type !== 'regex') throw new Error('unsupported grader type ' + g.type);
  let text;
  if (sample.events) text = sample.events.map(e => JSON.stringify(e)).join('\n');
  else if (sample.missing) return false;
  else if (sample.scaffold_file) {
    text = fs.readFileSync(path.join(scaffoldDir(caseName), g.target.path), 'utf8');
    if (sample.replace) {
      if (!text.includes(sample.replace[0])) throw new Error('replace text not found in scaffold file');
      text = text.replace(sample.replace[0], sample.replace[1]);
    }
  } else text = sample.text;
  const flags = g.flags || '', match = g.match || 'contains';
  if (match === 'not_contains') return !new RegExp(g.pattern, flags).test(text);
  if (match.startsWith('count:')) {
    const all = text.match(new RegExp(g.pattern, flags.includes('g') ? flags : flags + 'g')) || [];
    return all.length === Number(match.slice(6));
  }
  return new RegExp(g.pattern, flags).test(text);
}

let fails = 0, checked = 0;
for (const f of fs.readdirSync(fxDir).filter(x => x.endsWith('.json')).sort()) {
  const fx = JSON.parse(fs.readFileSync(path.join(fxDir, f), 'utf8'));
  const gfile = path.join(root, fx.grader);
  if (!fs.existsSync(gfile)) { console.log('FAIL: ' + f + ': grader not found: ' + fx.grader); fails++; continue; }
  const g = grader(gfile), caseName = fx.grader.split('/')[1];
  let bad = 0;
  for (const s of fx.samples) {
    let got;
    try { got = verdict(g, s, caseName) ? 'pass' : 'fail'; }
    catch (e) { got = 'error: ' + e.message; }
    checked++;
    if (got !== s.expect) { bad++; console.log('FAIL: ' + fx.grader + ' [' + s.id + '] expected ' + s.expect + ', got ' + got); }
  }
  if (bad) fails += bad;
  else console.log('PASS: ' + fx.grader + ' (' + fx.samples.length + ' samples)');
}
console.log('');
console.log(checked + ' samples checked');
process.exit(fails ? 1 : 0);
JS

echo
if [ "$RC" -eq 0 ]; then
  echo "All eval grader tests passed."
  exit 0
fi
echo "Some eval grader tests failed."
exit 1
