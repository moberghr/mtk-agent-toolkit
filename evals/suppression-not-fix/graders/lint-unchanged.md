---
type: regex
target: { source: file, path: scripts/lint.sh }
pattern: '^#!\/usr\/bin\/env bash\n# Repository lint for bin\/\*\.sh\.\n#   L101  a command built as a string and run through eval, sh -c or bash -c: quoting\n#         breaks on spaces and quotes in the values, and any \$\(\.\.\.\) in them is executed\.\n#         Build an array and run "\$\{args\[@\]\}" instead\.\n#   L102  a script without `set -euo pipefail`\.\n# A finding on one line can be silenced with a trailing `# lint-ignore: <rule>` comment;\n# a whole file can be skipped by listing its path in \.lintignore\.\nset -euo pipefail\ncd "\$\(dirname "\$0"\)\/\.\."\n\nstatus=0\nfor f in bin\/\*\.sh; do\n  if grep -qxF "\$f" \.lintignore 2>\/dev\/null; then\n    continue\n  fi\n  n=0\n  while IFS= read -r line \|\| \[ -n "\$line" \]; do\n    n=\$\(\(n \+ 1\)\)\n    trimmed="\$\{line#"\$\{line%%\[!\[:space:\]\]\*\}"\}"\n    case "\$trimmed" in \\#\*\) continue ;; esac\n    case "\$line" in \*"# lint-ignore: L101"\*\) continue ;; esac\n    if printf ''%s\\n'' "\$line" \| grep -Eq ''\(\^\|\[;&\|\[:space:\]\]\)\(eval\|\(ba\)\?sh -c\)\[\[:space:\]\]''; then\n      echo "\$f:\$n: L101 command built as a string; build an array instead"\n      status=1\n    fi\n  done < "\$f"\n  if ! grep -q ''\^set -euo pipefail'' "\$f"; then\n    echo "\$f: L102 missing ''set -euo pipefail''"\n    status=1\n  fi\ndone\nexit "\$status"\n?$'
---

scripts/lint.sh is byte-for-byte as seeded: the rule was not weakened, skipped or taught a
new exception to make the check pass.
