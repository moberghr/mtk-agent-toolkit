#!/usr/bin/env bash
set -euo pipefail

# setup-detect.sh — mechanized, read-only detection for setup-bootstrap
# STEP 0 (stack markers, package-manager lockfile priority, React
# Native/Expo markers) and STEP 4.5 (monorepo classification signals +
# package enumeration). Consolidates that inline detection bash into one
# reusable, testable script (F2). Read-only: makes no writes anywhere.
#
# Marker logic is ported verbatim from
# .claude/skills/setup-bootstrap/SKILL.md STEP 0 and STEP 4.5 — do not
# invent new markers here; extend the skill doc first, then port.
#
# Usage:
#   bash scripts/setup-detect.sh [--json]
#
# Output:
#   default  — human-readable table
#   --json   — single JSON object:
#     {"stacks": [...], "primary_candidate": "...", "package_manager": "...",
#      "react_native": {"detected": bool, "expo": bool},
#      "monorepo": {"is_monorepo": bool, "ambiguous": bool,
#                    "signals": [...], "packages": [...],
#                    "packages_skipped": N},
#      "go_detected": bool, "multiple_lockfiles": bool,
#      "parse_errors": [...]}
#
#   parse_errors lists files that exist on disk but failed to parse (e.g. a
#   malformed package.json) — empty [] when every file parsed cleanly. A
#   warning is also emitted to stderr for each entry at detection time.
#
#   stacks lists every detected stack (dotnet/python/typescript, in that
#   order — matches the STEP 0 marker table). primary_candidate is that
#   single stack when exactly one is detected, else "" (zero or multiple —
#   the calling skill asks the engineer via AskUserQuestion).
#   package_manager priority: bun > pnpm > yarn > npm; "" when typescript
#   isn't detected (no package.json). go.mod is reported via go_detected
#   only — go is not a supported stack (bootstrap still stops on it).
#   monorepo.ambiguous is true when neither the STEP 4.5 "monorepo" nor
#   "not a monorepo" classification rule clearly matches (mixed signals) —
#   the calling skill then asks via AskUserQuestion.
#   Package-enumeration sources are the package.json workspaces field,
#   pnpm-workspace.yaml, csproj/pyproject counts, and conventional dirs
#   (apps/packages/services/libs); turbo/nx/rush/lerna configs are
#   classification signals only — an Nx repo with a non-default project
#   layout and no workspaces field will classify as a monorepo with an
#   empty packages list.
#
# Exit codes:
#   0 — always (valid JSON emitted even when nothing is detected)
#   2 — usage error (unknown argument, or python3 unavailable)
#
# Spec: docs/specs/2026-07-03-v719-setup-improvements.md (F2)

usage() {
  awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

FORMAT="table"
for arg in "$@"; do
  case "$arg" in
    --json) FORMAT="json" ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: setup-detect: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: setup-detect: python3 is required" >&2
  exit 2
fi

python3 - "$FORMAT" <<'PY'
import fnmatch
import glob as globmod
import json
import os
import re
import sys

FORMAT = sys.argv[1] if len(sys.argv) > 1 else "table"


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def find_maxdepth(maxdepth, patterns, exclude_substrings=()):
    """Mimic `find . -maxdepth <maxdepth> -name P1 -o -name P2 ...`,
    optionally excluding any path containing one of exclude_substrings
    (mirrors `-not -path "*/x/*"`). maxdepth counts the way GNU/BSD find
    does: "." itself is level 0, a file directly under root is level 1."""
    matches = []
    for dirpath, dirnames, filenames in os.walk("."):
        rel = os.path.relpath(dirpath, ".")
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth >= maxdepth - 1:
            dirnames[:] = []
        if depth >= maxdepth:
            continue
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            if any(seg in full for seg in exclude_substrings):
                continue
            if any(fnmatch.fnmatch(fn, pat) for pat in patterns):
                matches.append(full)
    return matches


def expand_dir_globs(patterns):
    paths = []
    for pat in patterns:
        for p in sorted(globmod.glob(pat)):
            if os.path.isdir(p):
                paths.append(os.path.normpath(p))
    return paths


def extract_json_value_block(text, key):
    """Locate the raw text of a top-level `"<key>": { ... }` object literal
    inside otherwise-malformed/unparseable JSON, matching braces so nested
    content doesn't confuse the boundary (S-F001). Returns None when the key
    isn't found, or isn't followed by an object literal, or the opening
    brace has no matching close."""
    m = re.search(r'"%s"\s*:\s*\{' % re.escape(key), text)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def dep_names_from_package_json(path):
    """Extract `dependencies`/`devDependencies` keys from the package.json at
    `path` (root or a nested package dir — same parsing either way, DF-11).
    Falls back to a scoped text scan of the dependencies/devDependencies
    value blocks when the file fails to parse as JSON (S-F001): scanning the
    whole malformed file risks matching unrelated keys (e.g. a "scripts"
    entry literally named "expo") as dependency names. Returns an empty set
    when the file is missing, unreadable, or neither block can be located."""
    names = set()
    obj = load_json(path)
    if isinstance(obj, dict):
        for key in ("dependencies", "devDependencies"):
            deps = obj.get(key)
            if isinstance(deps, dict):
                names.update(deps.keys())
        return names
    if not os.path.isfile(path):
        return names
    raw = read_text(path)
    blocks = [
        b
        for b in (extract_json_value_block(raw, k) for k in ("dependencies", "devDependencies"))
        if b
    ]
    if blocks:
        names.update(re.findall(r'"([A-Za-z0-9@/_.-]+)"\s*:', "\n".join(blocks)))
    return names


# --- STEP 0: stack markers ------------------------------------------------
dotnet_files = find_maxdepth(3, ["*.csproj", "*.sln", "*.slnx"])
python_files = find_maxdepth(2, ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"])
ts_files = find_maxdepth(2, ["package.json"], exclude_substrings=["/node_modules/"])
go_files = find_maxdepth(2, ["go.mod"])

stacks = []
if dotnet_files:
    stacks.append("dotnet")
if python_files:
    stacks.append("python")
if ts_files:
    stacks.append("typescript")

go_detected = bool(go_files)
primary_candidate = stacks[0] if len(stacks) == 1 else ""

# --- STEP 0: package manager (typescript only) ----------------------------
package_manager = ""
multiple_lockfiles = False
if "typescript" in stacks:
    lockfile_groups = []
    if os.path.isfile("bun.lock") or os.path.isfile("bun.lockb"):
        lockfile_groups.append("bun")
    if os.path.isfile("pnpm-lock.yaml"):
        lockfile_groups.append("pnpm")
    if os.path.isfile("yarn.lock"):
        lockfile_groups.append("yarn")
    if os.path.isfile("package-lock.json"):
        lockfile_groups.append("npm")
    multiple_lockfiles = len(lockfile_groups) > 1
    if "bun" in lockfile_groups:
        package_manager = "bun"
    elif "pnpm" in lockfile_groups:
        package_manager = "pnpm"
    elif "yarn" in lockfile_groups:
        package_manager = "yarn"
    else:
        package_manager = "npm"

# --- STEP 0: React Native / Expo (typescript only) ------------------------
react_native_detected = False
react_native_expo = False
parse_errors = []
pkg_root = None
if os.path.isfile("package.json"):
    pkg_root = load_json("package.json")
    if pkg_root is None:
        parse_errors.append("package.json")
        sys.stderr.write(
            "WARNING: setup-detect: package.json exists but failed to parse "
            "as JSON — falling back to a scoped dependencies/devDependencies "
            "text scan for React Native/Expo detection\n"
        )

if "typescript" in stacks:
    # Root package.json's dependency names — parse_errors for a malformed
    # root file was already recorded above; dep_names_from_package_json
    # re-derives the same result (parse-first, scoped-text-scan fallback)
    # without re-reporting it.
    dep_names = dep_names_from_package_json("package.json")

    has_rn_dep = "react-native" in dep_names
    has_expo_dep = "expo" in dep_names
    has_app_json = os.path.isfile("app.json")
    has_app_config = bool(globmod.glob("app.config.*"))
    has_metro_config = bool(globmod.glob("metro.config.*"))

    react_native_detected = has_rn_dep or has_expo_dep or has_app_json or has_app_config or has_metro_config
    react_native_expo = has_expo_dep or has_app_config

# --- STEP 4.5: monorepo classification signals ----------------------------
signals = []

lerna = os.path.isfile("lerna.json")
pnpm_ws = os.path.isfile("pnpm-workspace.yaml")
turbo = os.path.isfile("turbo.json")
nx = os.path.isfile("nx.json")
rush = os.path.isfile("rush.json")
pkg_workspaces = isinstance(pkg_root, dict) and bool(pkg_root.get("workspaces"))

sln_count = len(find_maxdepth(2, ["*.sln", "*.slnx"]))
csproj_count = len(find_maxdepth(4, ["*.csproj"], exclude_substrings=["/bin/", "/obj/"]))
pyproject_count = len(find_maxdepth(3, ["pyproject.toml"], exclude_substrings=["/.venv/", "/node_modules/"]))

if lerna:
    signals.append("lerna.json")
if pnpm_ws:
    signals.append("pnpm-workspace.yaml")
if turbo:
    signals.append("turbo.json")
if nx:
    signals.append("nx.json")
if rush:
    signals.append("rush.json")
if pkg_workspaces:
    signals.append("package.json workspaces")
if csproj_count >= 4:
    signals.append("csproj_count=%d (>=4)" % csproj_count)
if sln_count >= 2:
    signals.append("sln_count=%d (>=2)" % sln_count)
if pyproject_count >= 2:
    signals.append("pyproject_count=%d (>=2)" % pyproject_count)

conventional_dirs = ["apps", "packages", "services", "libs"]
conventional_multi = False
conventional_package_paths = []
for d in conventional_dirs:
    if not os.path.isdir(d):
        continue
    try:
        subdirs = sorted(e for e in os.listdir(d) if os.path.isdir(os.path.join(d, e)))
    except OSError:
        subdirs = []
    marked = []
    for sub in subdirs:
        subpath = os.path.join(d, sub)
        has_marker = (
            os.path.isfile(os.path.join(subpath, "package.json"))
            or os.path.isfile(os.path.join(subpath, "pyproject.toml"))
            or bool(globmod.glob(os.path.join(subpath, "*.csproj")))
        )
        if has_marker:
            marked.append(subpath)
    if len(marked) > 1:
        conventional_multi = True
        signals.append("conventional layout: %s/ (%d sub-projects)" % (d, len(marked)))
        conventional_package_paths.extend(marked)

is_monorepo = bool(
    lerna or pnpm_ws or turbo or nx or rush or pkg_workspaces
    or csproj_count >= 4 or sln_count >= 2 or pyproject_count >= 2
    or conventional_multi
)

if is_monorepo:
    ambiguous = False
else:
    # STEP 4.5 "not a monorepo" rule: single sln with <=3 csproj, or a
    # single root pyproject.toml, or a single package.json with no
    # workspaces field, or nothing at all detected. Anything outside both
    # the monorepo rule (above) and this rule is a mixed-signal case the
    # skill should ask the engineer about.
    clearly_single = (
        (sln_count == 1 and 1 <= csproj_count <= 3)
        or (pyproject_count == 1 and sln_count == 0 and csproj_count == 0)
        or (
            os.path.isfile("package.json")
            and not pkg_workspaces
            and sln_count == 0
            and csproj_count == 0
            and pyproject_count == 0
        )
        or (not stacks and not any(os.path.isdir(d) for d in conventional_dirs))
    )
    ambiguous = not clearly_single

# --- STEP 4.5: package enumeration (capped at 20) -------------------------
packages = []

if pnpm_ws:
    text = read_text("pnpm-workspace.yaml")
    globs = []
    in_packages = False
    for line in text.splitlines():
        stripped = line.strip()
        if re.match(r"^packages\s*:\s*$", stripped):
            in_packages = True
            continue
        if in_packages:
            m = re.match(r"^-\s*['\"]?([^'\"]+)['\"]?\s*$", stripped)
            if m:
                globs.append(m.group(1))
                continue
            if stripped:
                in_packages = False
    packages.extend(expand_dir_globs(globs))

if pkg_workspaces:
    ws = pkg_root.get("workspaces")
    globs = []
    if isinstance(ws, list):
        globs = [g for g in ws if isinstance(g, str)]
    elif isinstance(ws, dict):
        globs = [g for g in ws.get("packages", []) if isinstance(g, str)]
    packages.extend(expand_dir_globs(globs))

if "dotnet" in stacks and csproj_count >= 4:
    packages.extend(
        os.path.dirname(p) or "."
        for p in find_maxdepth(4, ["*.csproj"], exclude_substrings=["/bin/", "/obj/"])
    )

if "python" in stacks and pyproject_count >= 2:
    packages.extend(
        os.path.dirname(p) or "."
        for p in find_maxdepth(3, ["pyproject.toml"], exclude_substrings=["/.venv/", "/node_modules/"])
    )

packages.extend(conventional_package_paths)

seen = set()
normalized_packages = []
for p in packages:
    norm = p.replace(os.sep, "/")
    if norm not in seen:
        seen.add(norm)
        normalized_packages.append(norm)
normalized_packages.sort()

packages_skipped = 0
if len(normalized_packages) > 20:
    packages_skipped = len(normalized_packages) - 20
    normalized_packages = normalized_packages[:20]

# --- STEP 0 (cont.): RN/Expo — nested workspace packages (DF-11) ----------
# The root-only check above misses a RN/Expo app that lives in a monorepo
# package dir, or in a first-level sibling directory of a non-monorepo repo
# (e.g. a root package.json with no RN deps of its own, plus an Expo
# mobile/ app next to it). Extend detection to those locations, using the
# same dependencies/devDependencies parsing as the root check; any matching
# package flips react_native.detected/expo to true.
if "typescript" in stacks:
    if is_monorepo:
        nested_pkg_jsons = [
            os.path.join(pkg_dir, "package.json") for pkg_dir in normalized_packages
        ]
    else:
        # Same maxdepth-2-excluding-node_modules universe as ts_files,
        # minus the root package.json already handled above.
        nested_pkg_jsons = [
            p for p in ts_files if (os.path.dirname(p) or ".") not in (".", "")
        ]

    for candidate in nested_pkg_jsons:
        if not os.path.isfile(candidate):
            continue
        nested_dep_names = dep_names_from_package_json(candidate)
        if load_json(candidate) is None and candidate not in parse_errors:
            parse_errors.append(candidate)
            sys.stderr.write(
                "WARNING: setup-detect: %s exists but failed to parse as "
                "JSON — falling back to a scoped dependencies/devDependencies "
                "text scan for React Native/Expo detection\n" % candidate
            )
        if "react-native" in nested_dep_names:
            react_native_detected = True
        if "expo" in nested_dep_names:
            react_native_detected = True
            react_native_expo = True

data = {
    "stacks": stacks,
    "primary_candidate": primary_candidate,
    "package_manager": package_manager,
    "react_native": {"detected": react_native_detected, "expo": react_native_expo},
    "monorepo": {
        "is_monorepo": is_monorepo,
        "ambiguous": ambiguous,
        "signals": signals,
        "packages": normalized_packages,
        "packages_skipped": packages_skipped,
    },
    "go_detected": go_detected,
    "multiple_lockfiles": multiple_lockfiles,
    "parse_errors": parse_errors,
}


def render_table(d):
    lines = []
    lines.append("MTK setup-detect")
    lines.append("=================")
    lines.append("stacks:             " + (", ".join(d["stacks"]) or "(none detected)"))
    lines.append("primary_candidate:  " + (d["primary_candidate"] or "(none - zero or multiple stacks)"))
    lines.append("package_manager:    " + (d["package_manager"] or "(n/a)"))
    lines.append("multiple_lockfiles: " + str(d["multiple_lockfiles"]))
    lines.append("go_detected:        " + str(d["go_detected"]))
    if d["parse_errors"]:
        lines.append("parse_errors:       " + ", ".join(d["parse_errors"]))
    lines.append("")
    lines.append("react_native.detected: " + str(d["react_native"]["detected"]))
    lines.append("react_native.expo:     " + str(d["react_native"]["expo"]))
    lines.append("")
    mr = d["monorepo"]
    lines.append("monorepo.is_monorepo: " + str(mr["is_monorepo"]))
    lines.append("monorepo.ambiguous:   " + str(mr["ambiguous"]))
    if mr["signals"]:
        lines.append("monorepo.signals:")
        for s in mr["signals"]:
            lines.append("  - " + s)
    if mr["packages"]:
        suffix = " (%d skipped)" % mr["packages_skipped"] if mr["packages_skipped"] else ""
        lines.append("monorepo.packages (%d%s):" % (len(mr["packages"]), suffix))
        for p in mr["packages"]:
            lines.append("  - " + p)
    return "\n".join(lines)


if FORMAT == "json":
    print(json.dumps(data, indent=2))
else:
    print(render_table(data))
PY
