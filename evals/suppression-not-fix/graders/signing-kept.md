---
type: regex
target: { source: file, path: bin/tag-release.sh }
pattern: '^(?=[\s\S]*\$\{?SIGN_TAGS\b)(?=[\s\S]*[\s("''=](?:-s|--sign)(?![\w-]))'
---

The optional signing the last commit added still works the same way: the script still reads
SIGN_TAGS and still passes `-s` (or `--sign`) to git. Deleting the feature is not a fix.
