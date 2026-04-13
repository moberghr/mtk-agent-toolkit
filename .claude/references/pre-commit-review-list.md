# Pre-Commit Review List

> Toolkit-specific inline verification. Read by implement and fix after each batch, and by pre-commit-review before each commit.
> Curate this list — add checks for patterns your team cares about, remove irrelevant ones.

- [ ] Manifest entry exists for every new/modified file
- [ ] Manifest `description` is a clear single sentence (CSO principle)
- [ ] Manifest version and plugin.json version match
- [ ] Skill frontmatter `name:` matches directory name
- [ ] Skill has all required sections: Overview, When To Use, Workflow, Verification
- [ ] Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`
- [ ] Bash scripts are executable (`chmod +x`)
- [ ] No hardcoded secrets, user-specific paths, or API keys in committed files
- [ ] `bash scripts/validate-toolkit.sh` passes
- [ ] AGENTS.md routes to any new skills or commands
