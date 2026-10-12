#!/usr/bin/env python3
"""repomap-tree-sitter.py — tree-sitter-driven symbol extraction + PageRank-ish ranking.

Called by scripts/repomap.sh. Output JSON schema matches repomap.sh.

This is intentionally a single file: the toolkit distributes as Bash + small
helper scripts; we don't want a Python package tree.

Graceful degradation: if tree-sitter bindings for the requested stack aren't
installed, we emit `fit: "fallback"` with `fallback_reason: "<missing-dep>"`.
"""
from __future__ import annotations
import argparse
import json
import os
import sys
from pathlib import Path


STACK_CONFIG = {
    "dotnet": {
        "module": "tree_sitter_c_sharp",
        "extensions": [".cs"],
        "kinds": {
            "class_declaration": "class",
            "interface_declaration": "interface",
            "struct_declaration": "struct",
            "record_declaration": "record",
            "method_declaration": "method",
        },
        "name_field": "name",
    },
    "python": {
        "module": "tree_sitter_python",
        "extensions": [".py"],
        "kinds": {
            "class_definition": "class",
            "function_definition": "function",
        },
        "name_field": "name",
    },
    "typescript": {
        "module": "tree_sitter_typescript",
        "extensions": [".ts", ".tsx"],
        "kinds": {
            "class_declaration": "class",
            "interface_declaration": "interface",
            "function_declaration": "function",
            "type_alias_declaration": "type",
        },
        "name_field": "name",
    },
}


def emit(out_path: Path, payload: dict) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2))


def fallback(out_path: Path, stack: str, reason: str) -> int:
    emit(out_path, {
        "stack": stack,
        "symbols": [],
        "edges": [],
        "token_estimate": 0,
        "fit": "fallback",
        "fallback_reason": reason,
    })
    print(f"repomap: fallback ({reason})", file=sys.stderr)
    return 0


def load_ignore_patterns(root: Path) -> list[str]:
    """Read .mtkignore (gitignore-like) plus built-in defaults.

    Patterns are returned as a flat list. fnmatch-style globs work directly;
    leading-slash anchors are stripped (we always match relative to root);
    trailing slashes are kept so we can detect directory-only patterns.
    """
    defaults = [
        ".git/", "node_modules/", "dist/", "bin/", "obj/",
        ".venv/", "venv/", "__pycache__/",
    ]
    patterns: list[str] = []
    mtkignore = root / ".mtkignore"
    if mtkignore.is_file():
        for line in mtkignore.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            patterns.append(line.lstrip("/"))
    patterns.extend(defaults)
    # dedup preserving order
    seen: set[str] = set()
    deduped: list[str] = []
    for p in patterns:
        if p not in seen:
            seen.add(p)
            deduped.append(p)
    return deduped


def _is_dir_ignored(rel_dir: str, dir_name: str, patterns: list[str]) -> bool:
    import fnmatch
    candidates = (rel_dir + "/") if rel_dir else f"{dir_name}/"
    for pat in patterns:
        if pat.endswith("/"):
            if fnmatch.fnmatch(dir_name + "/", pat) or fnmatch.fnmatch(candidates, pat):
                return True
        else:
            if fnmatch.fnmatch(dir_name, pat) or fnmatch.fnmatch(rel_dir, pat):
                return True
    return False


def _is_file_ignored(rel_path: str, file_name: str, patterns: list[str]) -> bool:
    import fnmatch
    for pat in patterns:
        if pat.endswith("/"):
            continue
        if fnmatch.fnmatch(file_name, pat) or fnmatch.fnmatch(rel_path, pat):
            return True
    return False


def collect_files(root: Path, exts: list[str]) -> list[Path]:
    patterns = load_ignore_patterns(root)
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_root = os.path.relpath(dirpath, root) if dirpath != str(root) else ""
        kept_dirs: list[str] = []
        for d in dirnames:
            if d.startswith("."):
                # Hidden dirs except those explicitly un-ignored later — match prior behavior.
                continue
            rel_child = f"{rel_root}/{d}" if rel_root else d
            if _is_dir_ignored(rel_child, d, patterns):
                continue
            kept_dirs.append(d)
        dirnames[:] = kept_dirs
        for fn in filenames:
            if not any(fn.endswith(ext) for ext in exts):
                continue
            rel_file = f"{rel_root}/{fn}" if rel_root else fn
            if _is_file_ignored(rel_file, fn, patterns):
                continue
            files.append(Path(dirpath) / fn)
    return files


def extract_symbols(files: list[Path], language, kinds: dict[str, str]) -> tuple[list[dict], list[dict]]:
    from tree_sitter import Parser  # type: ignore[import-not-found]

    parser = Parser()
    parser.set_language(language)

    symbols: list[dict] = []
    all_names: dict[str, dict] = {}
    edges: list[dict] = []

    for fp in files:
        try:
            src = fp.read_bytes()
        except OSError:
            continue
        tree = parser.parse(src)
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            kind = kinds.get(node.type)
            if kind:
                name_node = node.child_by_field_name("name")
                if name_node is not None:
                    name = src[name_node.start_byte:name_node.end_byte].decode("utf-8", errors="replace")
                    sym = {
                        "name": name,
                        "kind": kind,
                        "file": str(fp),
                        "refs": 0,
                    }
                    symbols.append(sym)
                    all_names.setdefault(name, sym)
            stack.extend(node.children)

    # Very simple reference-count pass: grep each symbol name in all source bytes once.
    # Avoids N^2 parse; trades accuracy for speed. PageRank-ish (in-edge count).
    corpus = b"\n".join(fp.read_bytes() for fp in files if fp.is_file())
    for sym in symbols:
        name_bytes = sym["name"].encode("utf-8")
        if len(name_bytes) < 3:
            continue  # ignore very short names — too many false hits
        sym["refs"] = max(0, corpus.count(name_bytes) - 1)  # minus self-declaration

    return symbols, edges


def rank_and_fit(symbols: list[dict], budget_tokens: int) -> tuple[list[dict], str]:
    """Sort by refs desc, binary-search the cut so the JSON fits under budget."""
    symbols.sort(key=lambda s: s["refs"], reverse=True)
    if not symbols:
        return symbols, "full"

    def estimate(subset: list[dict]) -> int:
        # ~1.3 tokens per word; each symbol ≈ 10 words of JSON.
        return int(len(subset) * 13)

    if estimate(symbols) <= budget_tokens:
        return symbols, "full"

    lo, hi = 1, len(symbols)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if estimate(symbols[:mid]) <= budget_tokens:
            lo = mid
        else:
            hi = mid - 1
    return symbols[:lo], "ranked"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack", required=True, choices=list(STACK_CONFIG.keys()))
    ap.add_argument("--budget", type=int, default=4000)
    ap.add_argument("--out", required=True)
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    out = Path(args.out)
    cfg = STACK_CONFIG[args.stack]

    try:
        from tree_sitter import Language  # type: ignore[import-not-found]
        mod = __import__(cfg["module"])
    except ImportError as e:
        return fallback(out, args.stack, f"import-error:{e.name}")

    try:
        language = Language(mod.language())
    except Exception as e:  # bindings version mismatch
        return fallback(out, args.stack, f"binding-error:{type(e).__name__}")

    files = collect_files(Path(args.root), cfg["extensions"])
    if not files:
        return fallback(out, args.stack, "no-source-files")

    symbols, edges = extract_symbols(files, language, cfg["kinds"])
    ranked, fit = rank_and_fit(symbols, args.budget)

    emit(out, {
        "stack": args.stack,
        "symbols": ranked,
        "edges": edges,
        "token_estimate": int(len(ranked) * 13),
        "fit": fit,
        "total_found": len(symbols),
        "files_scanned": len(files),
    })
    print(f"repomap: {len(ranked)}/{len(symbols)} symbols, fit={fit}, files={len(files)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
