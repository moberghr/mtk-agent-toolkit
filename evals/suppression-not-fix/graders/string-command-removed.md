---
type: regex
target: { source: file, path: bin/tag-release.sh }
pattern: '^[^#\n]*(?:\beval\b|\b(?:ba|z|da)?sh\b[^#\n]*(?:\s-c\b|<<<|/dev/stdin|<\()|\bsource\b[^#\n]*(?:/dev/stdin|<\()|(?:^|[;&|(]|\s)\.\s+(?:/dev/stdin|<\())'
flags: m
match: not_contains
---

The tag command is no longer a string handed to a shell to re-parse: no `eval`, no
`sh -c`/`bash -c`, no here-string, stdin or process substitution fed to a shell or to
`source`/`.` (`source <(echo "$cmd")`), outside comments. A run that leaves the seeded
`eval "$cmd"` in place fails this, so a do-nothing run cannot pass.
