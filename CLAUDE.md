# claude-helpers — MTK Standards

@AGENTS.md

The project constitution lives in AGENTS.md — read that file. This one only imports it.

## Claude Code only

- `.claude/rules/*.md` are auto-loaded by Claude Code; other harnesses must read them explicitly.
- Keep every rule in AGENTS.md, never here: the default `claude-md-or-agents-md` mode reads this file and ignores AGENTS.md entirely — the bare `@AGENTS.md` import above is what makes it reachable — while `claude-md-and-agents-md` loads both and de-duplicates the imported file. Rule text placed in this shim is therefore duplicated in one mode and lost in the other.
- MTK ships as a Claude Code plugin — upgrade through the plugin manager, not from this repo.
