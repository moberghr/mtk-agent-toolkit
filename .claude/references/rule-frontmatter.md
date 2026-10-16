---
description: Contract for the paths frontmatter on .claude/rules/*.md, which Claude Code uses to path-scope rule loading
globs: [".claude/rules/**"]
alwaysApply: false
---

# Rule Frontmatter Contract

`.claude/rules/*.md` files carry one frontmatter key, `paths:`. Claude Code loads a rule
file only when a file matching one of its globs is read or edited; a rule file with no
frontmatter loads into every session.

```yaml
---
paths:
  - "hooks/**"
  - "scripts/**"
---
```

- Derive the globs from the directories the rule's own sections cite. A rule with no
  defensible glob has no defensible scope: fold it into `AGENTS.md` or drop it.
- `"**"` makes a rule always-on again. Use it only for a rule that genuinely applies
  everywhere, and say why in a comment.
- A glob that matches nothing in the repo makes the rule dead weight; drop the rule.

There is no generated index and no hook-delivered rule layer: native `paths:` loading is
the whole mechanism. A task whose intent needs a rule whose paths did not match (a
security pass, a release) reads that rule file directly.
