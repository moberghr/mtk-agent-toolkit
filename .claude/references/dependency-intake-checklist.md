---
description: Six-criteria gate for adding any new third-party dependency. Criterion 0 (Existence & Legitimacy) runs first. Two Poors block.
globs: ["**/package.json", "**/*.csproj", "**/Directory.Packages.props", "**/requirements.txt", "**/pyproject.toml", "**/Pipfile", "**/poetry.lock", "**/go.mod", "**/Cargo.toml", "**/Gemfile", "**/composer.json"]
alwaysApply: false
---

# Dependency-Intake Checklist

Adding a third-party dependency is a long-lived decision. This gate runs whenever a dependency manifest changes (`pre-commit-review` and `security-and-hardening` invoke it). Score each criterion **Good / Acceptable / Poor** with a one-line rationale citing evidence. **Two Poors block; any single Poor requires explicit engineer override.**

Criterion 0 (Existence & Legitimacy) runs before any other scoring. A Poor on criterion 0 is an immediate block — there is no point scoring maintenance or license on a package that does not exist or is a typosquat.

## The Six Criteria

### 0. Existence & Legitimacy — does this package actually exist at the stated registry, and is it the real one?

Run the appropriate registry verification command before scoring any other criterion. A package recommended by an AI assistant, a blog post, or a hallucinated dependency must be verified against the live registry.

**Registry verification commands:**

| Stack | Command |
|---|---|
| .NET / NuGet | `dotnet package search <id> --exact-match` |
| Python / PyPI | `pip index versions <pkg>` |
| Node / npm | `npm view <pkg>` |
| Go | `go list -m <module>@latest` |
| Rust / crates.io | `cargo search <crate> --limit 5` |

**Scoring:**

| Score | Meaning |
|---|---|
| **Good** | Package exists at the official registry. Publish date ≥ 6 months ago. Repo link resolves and the repo name closely matches the package name. No known name-distance typosquat alerts. |
| **Acceptable** | Package exists. Published recently (< 6 months) but by a recognised organisation or maintainer. Minor name-distance similarity to a popular package with no suspicious overlap in scope. |
| **Poor** | Package not found at the registry **or** name closely resembles a popular package with suspiciously different scope (typosquat signal) **or** repo link is dead or redirects to an unrelated project. |

**Immediate block.** A Poor on criterion 0 blocks regardless of other scores. Do not install the package; report the finding with the exact registry output. If the package was AI-recommended, mark it `[ASSUMED]` in the plan and insert a `checkpoint:human-verify` step before any install.

### 1. Scope — does this dep solve a problem we could not solve in <50 LOC ourselves?

| Score | Meaning |
|---|---|
| **Good** | Non-trivial domain (cryptography, parsing, protocol impl, OS abstraction). Reimplementation would be wrong-headed. |
| **Acceptable** | Real value but possibly overkill — a lighter approach exists. |
| **Poor** | Wrapper, micro-utility, or three-line "is-odd"-class package. |

### 2. Maintenance — is the project alive?

| Score | Meaning |
|---|---|
| **Good** | Last release < 6 months. ≥2 active maintainers. Clear roadmap or recent PRs landing. |
| **Acceptable** | Last release 6–18 months OR sole maintainer who is still responsive to issues. |
| **Poor** | Last release > 18 months. No maintainer activity. Open critical issues unanswered. |

### 3. Size — is install + transitive footprint proportionate to value?

| Score | Meaning |
|---|---|
| **Good** | Adds < 500 KB; ≤ 5 transitive deps; no native build step. |
| **Acceptable** | Adds 500 KB – 5 MB; 5–20 transitive deps; or modest native build. |
| **Poor** | > 5 MB on disk; > 20 transitives; pulls in compilers/heavy SDKs; install reliably fails on CI. |

### 4. Security — supply-chain posture?

| Score | Meaning |
|---|---|
| **Good** | No open CVEs at the pinned version; package signed (npm provenance, sigstore, NuGet signing); maintainer 2FA-enforced; reproducible builds. |
| **Acceptable** | No known CVEs but missing signing or 2FA evidence; or low-severity advisory with available patch. |
| **Poor** | Open critical/high CVE at pinned version; recent typosquat/malicious-release history in the registry; install runs arbitrary postinstall scripts. |

### 5. License — compatible with our distribution?

| Score | Meaning |
|---|---|
| **Good** | MIT / Apache-2.0 / BSD-2/3-Clause / ISC / 0BSD / Unlicense / MPL-2.0 (file-level copyleft is acceptable for libraries). |
| **Acceptable** | LGPL with dynamic linking; commercial license that engineering already owns. |
| **Poor** | GPL / AGPL in non-GPL product; SSPL; "source-available" non-OSI; license unclear or absent. |

## Block Logic

- **Criterion 0 Poor** — immediate block regardless of other scores. Do not score further.
- **0 Poors (criteria 1–5)** — pass.
- **1 Poor (criteria 1–5)** — pass only with explicit engineer override (state the reason in the PR).
- **≥2 Poors (criteria 1–5)** — **block**. Find an alternative or vendor the small surface you actually need.

## Evidence Requirements

For each Poor, the reviewer must cite at least one concrete piece of evidence:
- For **maintenance**: link to last release or last commit date.
- For **size**: `du -sh` or registry "unpacked size" figure.
- For **security**: CVE ID, GHSA ID, or audit advisory.
- For **license**: SPDX identifier from the package metadata or `LICENSE` file.

A Poor without evidence is downgraded to Acceptable. We do not block on vibes.

## Output Shape (workflow artifact)

```json
{
  "results": {
    "dep_gate": {
      "manifest_file": "package.json",
      "added_deps": [
        {
          "name": "lodash",
          "version": "4.17.21",
          "scope": "Acceptable",
          "maintenance": "Good",
          "size": "Good",
          "security": "Good",
          "license": "Good",
          "rationales": {
            "scope": "Real utility breadth but partially redundant with stdlib in modern JS"
          }
        }
      ],
      "verdict": "pass | override | block",
      "blocked_reason": "<required when verdict=block>"
    }
  }
}
```

## When This Doesn't Apply

- Version bumps within the same major (no new package introduced) — skip the checklist; run vulnerability scan only.
- Internal/monorepo workspace dependencies — skip; they share the project's own posture.
- Test/dev-only dependencies — apply, but a single Poor in **size** or **license-acceptable** is auto-pass since they don't ship to production.
