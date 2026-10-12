---
description: All-stacks Claude Code permission baseline (permissions.allow / deny / ask) that setup-bootstrap merges into every target repo's .claude/settings.json
globs: [".claude/settings.json", ".claude/settings.local.json"]
alwaysApply: false
---

# Settings Baseline (all stacks)

`setup-bootstrap` merges this block into the target repo's `.claude/settings.json`
for every stack, alongside the active tech-stack skill's `## Settings Additions`.
Each `### <key>` below is the Claude Code permission list of the same name
(`permissions.allow`, `permissions.deny`, `permissions.ask`); merge is a union
with whatever the repo already has (`hooks/merge-settings.sh`). Each bullet is
one rule: the backticked text is the rule, anything after the dash is a note and
is not written.

There is no `permissions.allowedTools` settings key. A list written under that
name is ignored, so repos bootstrapped before this was fixed are repaired with
`scripts/migrate-settings-permissions.sh` (run by `setup-refresh`, and by
`mtk-doctor --fix`).

Rule syntax, from the Claude Code permissions docs:

- Rules are evaluated deny, then ask, then allow; the first match wins and an
  allow rule cannot carve an exception out of a deny or ask rule.
- `Read(...)` / `Edit(...)` take gitignore-style paths. A bare or `**/` pattern
  (`Read(**/.env)`) matches at any depth under the working directory, the root
  included; `./path` is anchored at the working directory. `Read` deny rules
  cover Claude's file tools, the file commands Claude Code recognizes in Bash
  (`cat`, `head`, `tail`, `sed`, `tee`) and redirect targets. They do not cover
  a command that reads files without naming them, such as `grep -r pattern .`.
- `Bash(...)` matches the whole command text; `*` matches any text, including
  spaces, and may appear anywhere. A rule does not match the same program
  invoked another way (`git -C . push`, `sh -c '...'`).

### allow

Nothing is pre-authorized for every stack. Each tech-stack skill's
`### allow (merge: union)` list carries its own build, test and format commands.

### deny

- `Read(**/.env)` — covers `./.env` and nested copies
- `Read(**/.env.*)` — `.env.local`, `.env.production`; also blocks `.env.example`, which rarely matters
- `Read(**/*.pem)`
- `Read(**/*.key)`
- `Read(**/*.pfx)`
- `Read(**/*.p12)`
- `Read(**/secrets/**)` — a directory named `secrets` at any depth
- `Read(**/secrets.json)`
- `Read(**/secrets.yaml)`
- `Read(**/secrets.yml)`
- `Read(**/*.secret)`

A blanket `Read(**/*secret*)` is deliberately absent: it also blocks source files
such as `SecretRotationService.cs` or `secret-store.ts`, which reviewers need to
read.

### ask

- `Bash(git push --force*)` — also matches `--force-with-lease`
- `Bash(git push -f*)`
- `Bash(git push * --force*)` — the flag after the remote or branch
- `Bash(git push * -f*)`
- `Bash(git push * +*)` — a `+refspec` is a force push
- `Bash(git reset --hard*)`
- `Bash(git reset * --hard*)`
- `Bash(git clean -*f*)` — `-f`, `-fd`, `-xdf`
- `Bash(dotnet ef database drop*)`
