# Batch: version consistency (2026-10-22) — 9.4.2

Scope note: no new public contract; no architectural change. One new script
(`scripts/stamp-version.sh`) replaces an inline snippet as the single writer of the repo
stamp.

Gate satisfied by explicit directive (2026-10-22). The engineer asked to "fix, unify them and
make sure moving forward we update all places correctly". They then chose "Merge #2 now" and
"Refresh-driven" for repo stamps, with no bulk edits in other repos.

Evidence for each place:

| Place | Showed | Status |
|---|---|---|
| moberg-plugins mtk entry | 8.0.1 | Duplicate `version`. Fixed by merging moberg-plugins#2: no version, `ref: plugin`. |
| Installed plugin | 9.4.0 | Updated to 9.4.1. |
| `.claude/mtk-version.json` stamps in about 20 repos | 7.0.0–7.35.0 | Session-start said "update available … use the plugin manager", which cannot change the stamp, and setup-refresh never bumped it. |

## Findings

1. **One stamp writer.** New `scripts/stamp-version.sh` writes or updates
   `.claude/mtk-version.json`:
   - `version` comes from the plugin manifest;
   - `installed` is kept;
   - `refreshed` is set on update;
   - the `coding-guidelines` pin is carried forward.

   `bootstrap-supporting-files.md` calls it instead of the inline snippet. Behavioral; test
   `test-stamp-version.sh`.
2. **setup-refresh bumps the stamp** when it finishes. Instruction change in its SKILL.md;
   covered by the script's test.
3. **Accurate session-start drift message.** The stamp parse tolerates whitespace; it used to
   miss `"version": "x"`. Old and new stamps get different messages:
   - stamp older than the plugin → "set up with X, plugin Y — run /mtk-setup --refresh";
   - stamp newer → "update the plugin".

   Behavioral; test.
4. **Doctor version lines.**
   - It now compares the setup stamp against the plugin: PASS when equal, WARN with
     `/mtk-setup --refresh` when older.
   - It WARNs when the marketplace the plugin was installed from lists an mtk `version` that
     differs from plugin.json. That is the stale-duplicate case.

   Behavioral; test.
5. **validate-toolkit release guards.** It FAILs when CHANGELOG.md has no `## [<version>]`
   heading or when the `checksums.sha256` header names another version. Structural; verified
   by running it.

## Post-batch

Release 9.4.2 with the three manifests, CHANGELOG, S4.6 rule text, the AGENTS.md C0.1 note
and checksums. Then run the full hook suite, validate and fixtures. Push and open the PR.
