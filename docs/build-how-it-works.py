#!/usr/bin/env python3
"""Build docs/how-it-works.html from docs/how-it-works.data.json.

The page is a generated, feature-by-feature reference for the MTK toolkit. To keep
it consistent with the marketing site it reuses the exact <style> block from
docs/index.html — so a design change there flows into this page on the next build.

Usage:
    python3 docs/build-how-it-works.py            # regenerate docs/how-it-works.html
    python3 docs/build-how-it-works.py --check     # staleness gate (no write); exit 1 on drift

Keeping it fresh:
    * Content lives in docs/how-it-works.data.json (one object per feature, with
      what / example / how / why). Edit the prose there and re-run the build.
    * `--check` compares the documented features against the skills, agents, and
      hooks actually on disk and reports anything undocumented or any source file
      a feature points at that no longer exists. Wire it into CI to fail on drift.
    * It detects STRUCTURAL drift (a feature added or removed). It cannot tell that
      a skill's behaviour changed while its file still exists — for that, re-derive
      the affected entries from source and update the JSON.
"""
import argparse
import html
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # .../docs
REPO_ROOT = os.path.dirname(HERE)                           # repo root
DATA_PATH = os.path.join(HERE, "how-it-works.data.json")
INDEX_PATH = os.path.join(HERE, "index.html")
OUT_PATH = os.path.join(HERE, "how-it-works.html")
GH_BLOB = "https://github.com/moberghr/mtk-agent-toolkit/blob/main/"

KIND_BADGE = {
    "skill": "badge--purple", "agent": "badge--warning", "hook": "badge--danger",
    "script": "badge--neutral", "reference": "badge--success", "concept": "badge--concept",
}

# Paths a feature may legitimately reference that are GENERATED into target repos
# by setup/runtime and therefore do not exist in the toolkit repo itself. --check
# reports these as expected (advisory), not as stale/removed references.
GENERATED_PREFIXES = (".claude/lessons/", ".claude/observability/", ".mtk/", "docs/specs/")
GENERATED_EXACT = {
    ".claude/tech-stack", ".claude/tool-configs.conf", ".claude/setup-answers.json",
    ".claude.local.md",
}
GENERATED_BASENAMES = {
    "architecture-principles.md", "conventions.md", "product.md", "decisions.md",
    "detected-tools.md", "CODE_INDEX.md", "AGENTS.md",
}


def is_generated(path):
    return (path in GENERATED_EXACT
            or path.startswith(GENERATED_PREFIXES)
            or os.path.basename(path) in GENERATED_BASENAMES)

SECTION_META = {
    "Setup": ("01", "Point MTK at a repo once. It detects your stack, pulls your team's standards, and generates the docs every later workflow reads.", "Bootstrap a repo & generate its standards."),
    "Plan": ("02", "Before a line of code: turn an ambiguous ask into an approved, hash-sealed spec and a plan broken into verifiable batches.", "Ambiguous ask → approved, sealed spec + plan."),
    "Build": ("03", "Execute the approved plan in batches that each compile, test, and stay inside the manifest — evidence gathered, drift checked.", "Batched, tested, evidence-backed execution."),
    "Review": ("04", "Adversarial, isolated-context reviewer agents plus deterministic linters. Findings are structured, cited to a rule, and block merge.", "Adversarial reviewers + deterministic linters."),
    "Learn": ("05", "Capture corrections and hard-won approaches as durable lessons, then promote the best of them team-wide — with a validated contribute-back path.", "Corrections & approaches become durable lessons."),
    "Operate": ("06", "Keep the install and the repo healthy: PASS/WARN/FAIL diagnostics, an AI-readiness scorecard, and honest usage signals.", "Diagnostics, scorecards, honest usage signals."),
    "Deterministic layer": ("07", "Hooks the harness runs for you — not the model. Advisory where a nudge is enough, blocking where a rule must hold 100% of the time.", "Hooks the harness enforces, not the model."),
    "Under the hood": ("08", "The machinery the workflows stand on: context budgeting, the rule wake-up layer, durable workflow artifacts, and the extensibility surface.", "Context, rules, artifacts, extensibility."),
}


# ---------- mini-markdown ----------
def esc(s):
    return html.escape(s, quote=False)


def inline(s):  # operates on already-escaped text
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return s


def paragraphs(text):
    out = []
    for p in re.split(r"\n\s*\n", text.strip()):
        p = p.strip()
        if p:
            out.append("<p>" + inline(esc(p)).replace("\n", " ") + "</p>")
    return "\n".join(out)


def render(text):
    """prose with embedded ```code``` blocks -> HTML"""
    if not text:
        return ""
    parts, idx = [], 0
    for m in re.finditer(r"```[^\n]*\n(.*?)```", text, re.DOTALL):
        pre = text[idx:m.start()]
        if pre.strip():
            parts.append(paragraphs(pre))
        parts.append('<div class="code-block"><pre>%s</pre></div>' % esc(m.group(1).rstrip("\n")))
        idx = m.end()
    tail = text[idx:]
    if tail.strip():
        parts.append(paragraphs(tail))
    return "\n".join(parts)


def kf_chips(files):
    if not files:
        return ""
    chips = []
    for p in files:
        p = (p or "").strip()
        if not p:
            continue
        if "/" in p and " " not in p:
            chips.append('<a class="kf" href="%s%s" target="_blank" rel="noopener"><code>%s</code></a>' % (GH_BLOB, p, esc(p)))
        else:
            chips.append('<span class="kf"><code>%s</code></span>' % esc(p))
    return '<div class="kf-row"><span class="kf-lbl">Source</span>%s</div>' % "".join(chips)


def feature_html(f):
    fid = "f-" + f["id"]
    facets = ['<div class="facet"><span class="facet-lbl">What it does</span>%s</div>' % render(f["what"])]
    if (f.get("example") or "").strip():
        facets.append('<div class="facet facet--ex"><span class="facet-lbl">Example</span>%s</div>' % render(f["example"]))
    facets.append('<div class="facet"><span class="facet-lbl">How it works</span>%s</div>' % render(f["how"]))
    facets.append('<div class="facet facet--why"><span class="facet-lbl">Why it works</span>%s</div>' % render(f["why"]))
    return """<article class="feature" id="{fid}">
  <div class="feature-head">
    <h3 class="feature-name"><a href="#{fid}" class="anchor" aria-label="Link to {name}">#</a>{name}</h3>
    <span class="badge {badge}">{kind}</span>
  </div>
  <p class="feature-lead">{one}</p>
  <p class="feature-inv"><span class="inv-lbl">Trigger</span> {inv}</p>
  <div class="facets">
    {facets}
  </div>
  {kf}
</article>""".format(
        fid=fid, name=esc(f["name"]), badge=KIND_BADGE.get(f["kind"], "badge--neutral"),
        kind=esc(f["kind"]), one=inline(esc(f["one_liner"])), inv=inline(esc(f["invocation"])),
        facets="\n    ".join(facets), kf=kf_chips(f.get("key_files")),
    )


PAGE_CSS = """
  /* === HOW-IT-WORKS PAGE === */
  /* clip (not hidden) kills any phantom horizontal scroll without making body a scroll container — keeps sticky TOC working */
  body { overflow-x: clip; }
  .badge--concept { background: var(--surface2); color: var(--text-muted); border: 1px solid var(--border); }
  .hiw-layout { display: grid; grid-template-columns: 248px minmax(0, 1fr); gap: 56px; align-items: start; }
  @media (max-width: 1040px) { .hiw-layout { grid-template-columns: 1fr; gap: 0; } }
  .hiw-section-wrap { min-width: 0; }
  .hiw-section-wrap .container { max-width: none; margin: 0; padding: 0; width: 100%; }
  .hiw-section-wrap .code-block { max-width: 100%; }

  .toc { position: sticky; top: 88px; align-self: start; }
  .toc-title { font-family: var(--font-body); font-size: 11px; font-weight: 600; letter-spacing: 1.5px; text-transform: uppercase; color: var(--text-dim); margin: 0 0 14px; padding-bottom: 10px; border-bottom: 1px solid var(--border); }
  .toc a { display: flex; align-items: center; gap: 10px; padding: 7px 10px; margin: 0 -10px; border-radius: 7px; color: var(--text-muted); text-decoration: none; font-size: 13.5px; font-weight: 500; line-height: 1.3; transition: background .12s, color .12s; }
  .toc a:hover { background: var(--surface2); color: var(--text); }
  .toc a.active { background: var(--accent-dim); color: var(--accent); }
  .toc .toc-num { font-family: var(--font-mono); font-size: 11px; color: var(--text-dim); }
  .toc a.active .toc-num { color: var(--accent); }
  .toc .toc-count { margin-left: auto; font-family: var(--font-mono); font-size: 11px; color: var(--text-dim); }
  .toc-legend { margin-top: 22px; padding-top: 18px; border-top: 1px solid var(--border); display: flex; flex-direction: column; gap: 7px; }
  .toc-legend .lg { display: inline-flex; align-items: center; gap: 8px; font-size: 12px; color: var(--text-muted); }
  @media (max-width: 1040px) { .toc { display: none; } }

  .sec-count { margin-left: auto; font-family: var(--font-mono); font-size: 11px; font-weight: 500; color: var(--text-dim); text-transform: none; letter-spacing: 0; }

  .qindex { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 40px; }
  .qchip { font-family: var(--font-mono); font-size: 11.5px; font-weight: 500; padding: 4px 10px; border-radius: var(--radius-pill); background: var(--surface); color: var(--text-muted); border: 1px solid var(--border); text-decoration: none; transition: border-color .12s, color .12s; max-width: 100%; }
  .qchip:hover { border-color: var(--accent); color: var(--accent); }

  .feature-list { display: flex; flex-direction: column; gap: 16px; }
  .feature { background: var(--surface); border: 1px solid var(--border); border-left: 3px solid var(--accent); border-radius: var(--radius-card); padding: 24px 28px 26px; scroll-margin-top: 88px; }
  .feature-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 6px; }
  .feature-name { font-family: var(--font-mono); font-size: 17px; font-weight: 600; color: var(--text); margin: 0; letter-spacing: -0.01em; overflow-wrap: anywhere; word-break: break-word; }
  .feature-name .anchor { color: var(--border-bright); text-decoration: none; margin-right: 8px; font-weight: 400; opacity: 0; transition: opacity .12s; }
  .feature:hover .feature-name .anchor { opacity: 1; }
  .feature-name .anchor:hover { color: var(--accent); }
  .feature-lead { font-size: 15.5px; color: var(--text); font-weight: 500; margin: 0 0 6px; line-height: 1.5; }
  .feature-inv { font-size: 13px; color: var(--text-muted); margin: 0 0 18px; line-height: 1.5; }
  .feature-inv .inv-lbl { font-family: var(--font-body); font-size: 10px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase; color: var(--text-dim); margin-right: 8px; }

  .facets { display: flex; flex-direction: column; gap: 16px; }
  .facet-lbl { display: block; font-family: var(--font-body); font-size: 10.5px; font-weight: 700; letter-spacing: 1.2px; text-transform: uppercase; color: var(--accent); margin-bottom: 7px; }
  .facet--why .facet-lbl { color: var(--text-dim); }
  .facet p { margin: 0 0 8px; color: var(--text-muted); font-size: 14.5px; line-height: 1.62; }
  .facet p:last-child { margin-bottom: 0; }
  .facet code { font-family: var(--font-mono); font-size: 12.5px; color: var(--accent); background: var(--accent-dim); padding: 1.5px 5px; border-radius: 4px; }
  .facet code, .feature-inv code, .feature-lead code, .feature-name, .qchip { overflow-wrap: anywhere; word-break: break-word; }
  .facet--why { background: var(--surface2); margin: 2px -12px -6px; padding: 14px 16px; border-radius: 8px; }
  .facet--why code { background: var(--surface); }

  .code-block { margin: 8px 0; background: #0E1218; border: 1px solid #1f2532; border-radius: 8px; overflow: hidden; }
  .code-block pre { margin: 0; padding: 14px 18px; font-family: var(--font-mono); font-size: 12.5px; line-height: 1.7; color: #CFD4E2; overflow-x: auto; white-space: pre; }

  .kf-row { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 18px; padding-top: 16px; border-top: 1px solid var(--border); }
  .kf-lbl { font-family: var(--font-body); font-size: 10px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase; color: var(--text-dim); margin-right: 4px; }
  .kf { text-decoration: none; }
  .kf code { font-family: var(--font-mono); font-size: 11.5px; color: var(--text-muted); background: var(--surface2); border: 1px solid var(--border); padding: 2px 8px; border-radius: 5px; transition: border-color .12s, color .12s; }
  a.kf:hover code { border-color: var(--accent); color: var(--accent); }

  .journey { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-top: 40px; }
  @media (max-width: 880px) { .journey { grid-template-columns: repeat(2, 1fr); } }
  @media (max-width: 520px) { .journey { grid-template-columns: 1fr; } }
  .jcard { display: block; padding: 18px 18px 16px; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius-card); text-decoration: none; transition: border-color .15s, transform .15s; }
  .jcard:hover { border-color: var(--accent); transform: translateY(-2px); }
  .jcard .jnum { font-family: var(--font-mono); font-size: 11px; color: var(--text-dim); }
  .jcard .jname { font-family: var(--font-body); font-size: 15px; font-weight: 600; color: var(--text); margin: 8px 0 4px; }
  .jcard .jdesc { font-size: 12.5px; color: var(--text-muted); line-height: 1.5; margin: 0; }
  .jcard .jcount { display: inline-block; margin-top: 10px; font-family: var(--font-mono); font-size: 10.5px; color: var(--accent); background: var(--accent-dim); padding: 2px 8px; border-radius: var(--radius-pill); }

  .to-top { position: fixed; right: 24px; bottom: 24px; width: 42px; height: 42px; border-radius: 50%; background: var(--accent); color: #fff; display: none; align-items: center; justify-content: center; box-shadow: 0 6px 20px rgba(78,14,255,.28); z-index: 50; text-decoration: none; transition: background .15s, transform .15s; }
  .to-top:hover { background: var(--accent-dark); transform: translateY(-2px); color: #fff; }
  .to-top.show { display: inline-flex; }

  .callout-note { display: flex; gap: 14px; align-items: flex-start; padding: 18px 20px; background: var(--accent-dim); border: 1px solid color-mix(in srgb, var(--border) 40%, var(--accent) 30%); border-radius: var(--radius-card); margin-bottom: 8px; }
  .callout-note svg { flex-shrink: 0; color: var(--accent); margin-top: 2px; }
  .callout-note p { margin: 0; font-size: 14px; color: var(--text-muted); line-height: 1.6; }
  .callout-note kbd { font-family: var(--font-mono); font-size: 11px; background: var(--surface); border: 1px solid var(--border); border-radius: 4px; padding: 1px 5px; }
"""


def build():
    data = json.load(open(DATA_PATH, encoding="utf-8"))
    feats = data["features"]
    cats = data.get("categories", list(SECTION_META.keys()))

    idx = open(INDEX_PATH, encoding="utf-8").read()
    style_m = re.search(r"<style>(.*?)</style>", idx, re.DOTALL)
    favicon_m = re.search(r'<link rel="icon"[^>]*>', idx)
    if not style_m or not favicon_m:
        sys.exit("build: could not find the shared <style> block or favicon <link> in %s "
                 "— has the design system moved out of index.html?" % os.path.relpath(INDEX_PATH, REPO_ROOT))
    style_inner = style_m.group(1)
    favicon = favicon_m.group(0)
    font_links = "\n".join(re.findall(r'<link[^>]*fonts[^>]*>', idx))

    by_cat = {c: [] for c in cats}
    for f in feats:
        by_cat.setdefault(f.get("category", "Under the hood"), []).append(f)

    def sec_id(name):
        return "sec-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

    sections_html, sidebar, journey = [], [], []
    for name in cats:
        items = by_cat.get(name, [])
        if not items:
            continue
        num, blurb, short = SECTION_META.get(name, ("", "", name))
        sid = sec_id(name)
        alt = " section--alt" if num in ("02", "04", "06", "08") else ""
        chips = "".join('<a class="qchip" href="#f-%s">%s</a>' % (f["id"], esc(f["name"])) for f in items)
        feats_html = "\n".join(feature_html(f) for f in items)
        sections_html.append("""<section class="section{alt} hiw-sec" id="{sid}">
  <div class="container">
    <div class="sec-head"><span class="sec-num">{num}</span> {name} <span class="sec-count">{n} {noun}</span></div>
    <p class="lede">{blurb}</p>
    <div class="qindex">{chips}</div>
    <div class="feature-list">
    {feats}
    </div>
  </div>
</section>""".format(alt=alt, sid=sid, num=num, name=esc(name), n=len(items),
                     noun="entry" if len(items) == 1 else "entries",
                     blurb=esc(blurb), chips=chips, feats=feats_html))
        sidebar.append('<a href="#%s" data-sec="%s"><span class="toc-num">%s</span> %s <span class="toc-count">%d</span></a>' % (sid, sid, num, esc(name), len(items)))
        journey.append('<a class="jcard" href="#%s"><span class="jnum">%s</span><div class="jname">%s</div><p class="jdesc">%s</p><span class="jcount">%d</span></a>' % (sid, num, esc(name), esc(short), len(items)))

    total = len(feats)
    n_skills = sum(1 for f in feats if f["kind"] == "skill")
    legend = "".join('<span class="lg"><span class="badge %s">%s</span></span>' % (cls, k) for k, cls in KIND_BADGE.items())

    head = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>How MTK works — feature by feature · Moberg</title>
<meta name="description" content="Every MTK feature explained: what it does, a real example, and how &amp; why it works. {total} mechanisms across setup, planning, build, review, lessons, operations, the deterministic hook layer, and the machinery under the hood." />
<meta property="og:title" content="How MTK works — feature by feature · Moberg" />
<meta property="og:description" content="Every MTK skill, agent, hook, and mechanism — what it does, an example, and how &amp; why it works." />
<meta property="og:type" content="website" />
{favicon}
{fonts}
<style>{style}{pagecss}</style>
</head>
<body>

<header class="nav">
  <div class="container nav-inner">
    <a href="index.html" class="brand" aria-label="Moberg · MTK home">
      <img src="assets/logo-wordmark-dark.svg" alt="Moberg" class="brand-wordmark" height="22">
      <span class="brand-sep">·</span>
      <span class="brand-product">MTK</span>
    </a>
    <nav class="nav-links">
      <a href="index.html">Overview</a>
      <a href="#{setup}">Setup</a>
      <a href="#{build}">Build</a>
      <a href="#{review}">Review</a>
      <a href="https://github.com/moberghr/mtk-agent-toolkit" class="cta">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .5C5.73.5.75 5.48.75 11.75c0 5 3.24 9.24 7.73 10.74.57.1.78-.25.78-.55v-1.93c-3.14.68-3.81-1.51-3.81-1.51-.51-1.3-1.25-1.65-1.25-1.65-1.02-.7.08-.68.08-.68 1.13.08 1.72 1.16 1.72 1.16 1 1.72 2.63 1.22 3.27.93.1-.73.39-1.22.71-1.5-2.51-.29-5.15-1.25-5.15-5.57 0-1.23.44-2.23 1.16-3.02-.12-.29-.5-1.43.11-2.98 0 0 .95-.3 3.1 1.15a10.8 10.8 0 0 1 5.64 0c2.15-1.45 3.1-1.15 3.1-1.15.61 1.55.23 2.69.11 2.98.72.79 1.16 1.79 1.16 3.02 0 4.33-2.64 5.28-5.16 5.56.4.35.76 1.04.76 2.1v3.11c0 .3.2.66.79.55 4.49-1.5 7.73-5.74 7.73-10.74C23.25 5.48 18.27.5 12 .5Z"/></svg>
        GitHub
      </a>
    </nav>
  </div>
</header>

<section class="hero" style="padding:72px 0 32px">
  <div class="container animate">
    <div class="hero-eyebrow"><span class="dot"></span> How it works · feature reference</div>
    <h1>How MTK works,<br><em>feature by feature</em>.</h1>
    <p class="hero-sub">
      The <a href="index.html#how">overview</a> shows the four-stage pipeline. This is the full reference: every skill, agent, hook, and mechanism — what it does, a real example, and how &amp; why it works. Every claim on this page was checked against the toolkit's own source.
    </p>
    <div class="hero-actions">
      <a href="index.html" class="btn btn--secondary">← Back to overview</a>
      <a href="#{setup}" class="btn btn--primary">Start at Setup
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"/></svg>
      </a>
    </div>
    <div class="hero-stats">
      <span>{total} mechanisms documented</span>
      <span>{skills} skills · 6 review agents</span>
      <span>checked against source</span>
    </div>
    <div class="journey">{journey}</div>
  </div>
</section>

<div class="divider"></div>

<div class="container" style="padding-top:56px;padding-bottom:24px">
  <div class="hiw-layout">
    <aside class="toc">
      <div class="toc-title">On this page</div>
      <nav>{sidebar}</nav>
      <div class="toc-legend">{legend}</div>
    </aside>
    <main class="hiw-section-wrap">
      <div class="callout-note">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
        <p>Entries are grouped by where they sit in the workflow. The first six groups follow a feature's journey from setup to operations; the last two are the deterministic hook layer and the machinery underneath. Use the list on the left to jump, or <kbd>Ctrl</kbd>/<kbd>⌘</kbd>+<kbd>F</kbd> to search.</p>
      </div>
""".format(total=total, skills=n_skills, favicon=favicon, fonts=font_links,
           style=style_inner, pagecss=PAGE_CSS, journey="".join(journey),
           sidebar="\n".join(sidebar), legend=legend,
           setup=sec_id("Setup"), build=sec_id("Build"), review=sec_id("Review"))

    tail = """
    </main>
  </div>
</div>

<section class="section">
  <div class="container">
    <div class="callout">
      <h2>That's the whole toolkit.</h2>
      <p>One command bootstraps it, one command routes everything else. The discipline above runs on every feature you ship — so "it works" finally means it works.</p>
      <div style="display:flex;gap:12px;flex-wrap:wrap">
        <a href="index.html#install" class="btn btn--primary">Install MTK</a>
        <a href="https://github.com/moberghr/mtk-agent-toolkit" class="btn btn--secondary">View on GitHub</a>
      </div>
    </div>
  </div>
</section>

<footer class="footer">
  <div class="container footer-inner">
    <div style="display:inline-flex;align-items:center;gap:12px">
      <img src="assets/favicon.svg" alt="" width="22" height="22" aria-hidden="true" style="border-radius:5px">
      <span>MTK — built by <a href="https://www.moberg.hr">Moberg</a>. Serious engineering, infinite possibilities.</span>
    </div>
    <div class="footer-links">
      <a href="index.html">Overview</a>
      <a href="https://github.com/moberghr/mtk-agent-toolkit">GitHub</a>
      <a href="https://github.com/moberghr/mtk-agent-toolkit/blob/main/CHANGELOG.md">Changelog</a>
      <span class="footer-legal">MIT</span>
    </div>
  </div>
</footer>

<a href="#" class="to-top" aria-label="Back to top">
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 15l-6-6-6 6"/></svg>
</a>

<script>
(function(){
  var links = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  var secs = links.map(function(a){ return document.getElementById(a.getAttribute('data-sec')); });
  var toTop = document.querySelector('.to-top');
  function onScroll(){
    var y = window.scrollY + 120, cur = -1;
    for (var i=0;i<secs.length;i++){ if (secs[i] && secs[i].offsetTop <= y) cur = i; }
    links.forEach(function(a,i){ a.classList.toggle('active', i===cur); });
    if (toTop) toTop.classList.toggle('show', window.scrollY > 600);
  }
  window.addEventListener('scroll', onScroll, {passive:true});
  onScroll();
})();
</script>

</body>
</html>
"""
    page = head + "\n".join(sections_html) + tail
    open(OUT_PATH, "w", encoding="utf-8").write(page)
    print("Built %s" % os.path.relpath(OUT_PATH, REPO_ROOT))
    print("  %d features · %d skills · %.0f KB" % (total, n_skills, len(page.encode("utf-8")) / 1024))
    for name in cats:
        if by_cat.get(name):
            print("    %-22s %d" % (name, len(by_cat[name])))
    return 0


def check():
    """Structural staleness gate: skills/agents/hooks on disk vs. documented features."""
    data = json.load(open(DATA_PATH, encoding="utf-8"))
    feats = data["features"]

    # everything referenced by the docs, for coverage + reverse checks
    all_key_files = set()
    name_blob = " ".join((f.get("name", "") + " " + f.get("id", "")) for f in feats)
    for f in feats:
        for p in (f.get("key_files") or []):
            all_key_files.add((p or "").strip())

    def documented(path, dir_or_base=None):
        if path in all_key_files:
            return True
        return bool(dir_or_base) and dir_or_base in name_blob

    undocumented, stale, generated = [], [], []

    # skills
    skills_dir = os.path.join(REPO_ROOT, ".claude", "skills")
    if os.path.isdir(skills_dir):
        for d in sorted(os.listdir(skills_dir)):
            if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")):
                if not documented(".claude/skills/%s/SKILL.md" % d, d):
                    undocumented.append("skill   %s" % d)
    # agents
    agents_dir = os.path.join(REPO_ROOT, ".claude", "agents")
    if os.path.isdir(agents_dir):
        for fn in sorted(os.listdir(agents_dir)):
            if fn.endswith(".md"):
                base = fn[:-3]
                if not documented(".claude/agents/%s" % fn, base):
                    undocumented.append("agent   %s" % base)
    # hooks (top-level .sh) — advisory only
    hooks_dir = os.path.join(REPO_ROOT, "hooks")
    undoc_hooks = []
    if os.path.isdir(hooks_dir):
        for fn in sorted(os.listdir(hooks_dir)):
            if fn.endswith(".sh"):
                if not documented("hooks/%s" % fn, fn):
                    undoc_hooks.append("hook    %s" % fn)

    # reverse: documented source files that no longer exist
    for p in sorted(all_key_files):
        if not p or " " in p or "/" not in p:
            continue
        if not os.path.exists(os.path.join(REPO_ROOT, p)):
            (generated if is_generated(p) else stale).append(p)

    print("how-it-works.html staleness check")
    print("  documented features : %d" % len(feats))
    hard = undocumented or stale

    if undocumented:
        print("\n  UNDOCUMENTED (on disk, missing from how-it-works.data.json):")
        for u in undocumented:
            print("    - %s" % u)
    if stale:
        print("\n  STALE REFERENCES (documented source file no longer exists):")
        for s in stale:
            print("    - %s" % s)
    if undoc_hooks:
        print("\n  note — hooks not individually documented (advisory, not a failure):")
        for u in undoc_hooks:
            print("    - %s" % u)
    if generated:
        print("\n  note — references to files generated into target repos, not committed here (expected):")
        for g in generated:
            print("    - %s" % g)

    if hard:
        print("\nDRIFT: update docs/how-it-works.data.json (then run the build) and re-check.")
        return 1
    print("\nOK — every skill and agent is documented and no source reference is stale.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Build or check docs/how-it-works.html")
    ap.add_argument("--check", action="store_true", help="staleness gate only; no write; exit 1 on drift")
    args = ap.parse_args()
    sys.exit(check() if args.check else build())


if __name__ == "__main__":
    main()
