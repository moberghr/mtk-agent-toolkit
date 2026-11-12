#!/usr/bin/env bash
set -euo pipefail

# Security-gate BACKSTOP: the de0c626 pattern set, kept verbatim (functions
# renamed mtk_bs_*). hooks/security-gate.sh runs its precise token checks AND
# this crude regex layer over the same text, and denies on a hit from either.
#
# Why keep the crude layer: the regexes match `rm -rf ~`, a force push to main
# or destructive SQL ANYWHERE in an executable segment, so they catch shapes a
# tokeniser does not model (a command hidden in an env var, an alias value, a
# quoted fragment, a heredoc written then run). Each time the precise checks
# replaced them outright, some of those shapes started passing again. The union
# makes the precise layer purely additive: it can only deny more.
#
# Do not "improve" the regexes here. New coverage belongs in security-gate.sh;
# this file's job is to keep base behaviour as a floor.
#
# One deliberate narrowing: the rm floor used to deny any recursive force
# delete whose FIRST operand started with . / ~ or $HOME, so
# `rm -rf ./node_modules` and `rm -rf /tmp/build-abc` were denied while
# `rm -rf build /` passed. A delete the 9.4.2 gate denied is now allowed only
# when EVERY operand is on an allow-list; one it allowed stays allowed unless
# it is one of the named bypasses (rm_broad in MTK_RM_AWK below, the one
# definition security-gate.sh uses too).
#
# Requires hooks/lib/hook-io.sh (mtk_repo_root, mtk_repo_relative_path).

# Prefix words (assignments, control words, wrappers) the segment judges peel
# before the command word. A real command has a handful; past this bound the
# whole segment is judged instead, so a 32 KB `time time time …` chain costs
# one pass. security-gate.sh also denies such a segment up front.
MTK_GATE_MAX_PREFIX=128

# Self-deadline. The harness gives the hook 5 s and treats a timed-out hook as
# non-blocking, so a command that takes longer to judge would run unjudged.
# Every judging loop checks the shell's own clock ($SECONDS, a builtin: no
# process) and, once judging has run MTK_SECURITY_GATE_DEADLINE_SECS (default
# 3) seconds, stops and denies. $SECONDS counts whole seconds since the shell
# started, so the deny comes between DEADLINE-1 and DEADLINE seconds in.
MTK_GATE_DEADLINE="${MTK_SECURITY_GATE_DEADLINE_SECS:-}"
case "$MTK_GATE_DEADLINE" in ''|*[!0-9]*|0*) MTK_GATE_DEADLINE=3 ;; esac
# Shells nested inside `bash -c` text deeper than this are not judged level by
# level; the command is denied as too complex instead.
MTK_GATE_MAX_NEST=8
# Lines the segment judges print instead of judged text. The callers turn
# either into a deny; command text can forge them only to get itself denied.
MTK_GATE_LATE='@@MTK_GATE_LATE@@'
MTK_GATE_SPLITERR='@@MTK_GATE_SPLITERR@@'
MTK_SPLIT_END='@@MTK_SPLIT_END@@'
MTK_GATE_LATE_REASON='this command is too complex for the security gate to judge in time (too long, or shells nested too deep). Split it into smaller commands, or move it into a script file and run that.'
MTK_GATE_SPLITERR_REASON='the security gate could not split this command into segments. Re-run it in a simpler form.'

MTK_RM_DENY_REASON='Recursive force-delete of a path that is not specific. Only literal paths inside the working directory or under /tmp may be deleted recursively: no home path, $VAR, $(…), glob, brace, or `.`/`..` component.'
MTK_RM_GIT_REASON='Recursive force-delete of a .git directory destroys the repository and its unpushed history.'
MTK_RM_XARGS_REASON='xargs rm -rf deletes whatever arrives on stdin. Delete specific paths instead.'

# MTK_RM_AWK: which recursive force-deletes are allowed. Shared as awk source
# by the backstop below and by the token checks in security-gate.sh; prepend
# it to an awk program and call rm_broad(line) on one segment of shell text.
#
# rm_broad(line) is 0 when the line is clean, 1 when a recursive force delete
# is denied, 2 when the only problem is a .git component, 3 when it deletes
# whatever xargs feeds it. The decision is anchored on the 9.4.2 gate
# (head_broad, below): what it denied stays denied unless EVERY operand is on
# the allow-list; what it allowed stays allowed except these named bypasses:
#   - a `..` component in any operand (build/.., a/../..);
#   - a .git component anywhere (foo/.git);
#   - the command word holds an expansion ($x -rf, r${E}m -rf,
#     $(which rm) -rf) and an operand is off the allow-list;
#   - an earlier cd/pushd to a target that is not literal, `-`, none, has a
#     `..` or .git component, or is absolute outside /tmp and the working
#     directory, then a relative operand (cd /etc && <delete> x);
#   - a construct the word splitter does not model: a standalone { or }, a (
#     among the operands (x(y), <( … )),
#     an escaped separator (x\;y), an fd close/dup or clobber redirect
#     (>&- <&0 >|), a here-doc, or a backslash-newline (MTKBSNL=1, added by
#     the segment splitter): then any operand that looks broad denies.
# Operands are the words after the command word up to a command boundary or
# an unquoted `#` word (a comment); redirect targets are not operands. Each
# line is judged raw (quotes honoured) and again with quotes and backslashes
# removed (so "rm" -rf / and r\m -rf / are still rm); rm_legacy keeps the
# 8.0.3 regex shape `rm -<x>r<x>f<x> <. / ~ $HOME>` (it matched farm -rf / too).
#
# specific_path(w) is the allow-list for one operand w (a shell word as
# written; balanced quotes are fine, so "my dir" is the literal my dir):
#   - fully literal: no $ ` { } * ? [ ~ and no unclosed quote;
#   - no `.` or `..` component (a single leading ./ excepted) and no .git
#     component in any letter case;
#   - relative with at least one real component (build, .next, ./dist/tmp),
#     or absolute with at least one real component below /tmp/ or
#     /private/tmp/ (/tmp/build-abc).
#
# Linear: each word is visited a fixed number of times.
MTK_RM_AWK='
function unquote(w,   n, ch, i, c, q, u) {
  UQBAD = 0; n = split(w, ch, ""); u = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (q == "\047") { if (c == "\047") q = ""; else u = u c; continue }
    if (q == "\"") {
      if (c == "\\" && i < n && ch[i + 1] ~ /["\\$`]/) { i++; u = u ch[i]; continue }
      if (c == "\"") q = ""; else u = u c
      continue
    }
    if (c == "\\") { if (i < n) { i++; u = u ch[i] } continue }
    if (c == "\047" || c == "\"") { q = c; continue }
    u = u c
  }
  if (q != "") UQBAD = 1
  return u
}
function specific_path(w,   p, n, c, i, real) {
  RMGIT = 0
  if (length(w) > 1024 || w ~ /[$`{}*?[~]/) return 0
  p = unquote(w)
  if (UQBAD || p == "") return 0
  n = split(p, c, "/")
  i = 1
  if (substr(p, 1, 1) == "/") {
    i = 2; while (i <= n && c[i] == "") i++
    if (c[i] == "private") { i++; while (i <= n && c[i] == "") i++ }
    if (c[i] != "tmp") return 0
    i++
  } else if (c[1] == "." && n > 1) i = 2
  real = 0
  for (; i <= n; i++) {
    if (c[i] == "") continue
    if (c[i] == "." || c[i] == "..") return 0
    if (tolower(c[i]) == ".git") { RMGIT = 1; return 0 }
    real++
  }
  return real > 0
}
# A cd/pushd target that keeps a later relative delete where it was meant:
# literal, no `..` or .git component, and relative, or absolute at or below
# /tmp, /private/tmp or the working directory (not / and not $HOME itself).
function cd_ok(w,   p, n, c, i, cwd) {
  if (w == "" || w == "-" || w ~ /[$`~{}*?[\\]/) return 0
  p = unquote(w)
  if (UQBAD || p == "") return 0
  n = split(p, c, "/")
  for (i = 1; i <= n; i++) if (c[i] == ".." || tolower(c[i]) == ".git") return 0
  if (substr(p, 1, 1) != "/") return 1
  if (p ~ /^\/(private\/)?tmp(\/|$)/) return 1
  cwd = ENVIRON["MTK_GATE_CWD"]
  if (cwd != "" && cwd != "/" && cwd != ENVIRON["HOME"] && (p == cwd || index(p, cwd "/") == 1)) return 1
  return 0
}
# Does word u (quotes and backslashes removed) look broad to the 9.4.2 rule:
# a piece, cut at ( ) { } ` and commas, starting with . / ~ $ or *?
function looks_broad(u,   P, n, k) {
  n = split(u, P, /[(){}`,]+/)
  for (k = 1; k <= n; k++) if (P[k] ~ /^[.\/~$*]/) return 1
  return 0
}
function odd_bs(w,   n, k) {
  n = length(w); k = 0
  while (n > 0 && substr(w, n, 1) == "\\") { k++; n-- }
  return k % 2
}
# The 9.4.2 gate on one line, widened only to cut brace alternatives at
# commas and to read abbreviated long options: quotes and backslashes removed,
# words split at blanks ( ) { } ` and commas; an rm with -r and -f whose later
# words include one starting
# with . / ~ $ or *, or that has no later word, is broad. Every later word
# counts, redirect targets and comments included.
function head_broad(line,   l, t, n, k, m, b, rec, frc, flags, paths, broad) {
  l = line; gsub(/[\\"\047]/, "", l)
  n = split(l, t, /[ \t(){}`,]+/)
  for (k = 1; k <= n; k++) {
    b = t[k]; sub(/^.*\//, "", b)
    if (b != "rm") continue
    rec = 0; frc = 0; flags = 1; paths = 0; broad = 0
    for (m = k + 1; m <= n; m++) {
      if (t[m] == "") continue
      if (flags && t[m] == "--") { flags = 0; continue }
      if (flags && t[m] ~ /^--/) {
        # GNU rm takes any unambiguous abbreviation (--rec, --forc).
        if (length(t[m]) >= 3 && index("--recursive", t[m]) == 1) rec = 1
        if (length(t[m]) >= 3 && index("--force", t[m]) == 1) frc = 1
        continue
      }
      if (flags && t[m] ~ /^-/) { if (t[m] ~ /[rR]/) rec = 1; if (t[m] ~ /f/) frc = 1; continue }
      paths++
      if (t[m] ~ /^[.\/~$*]/) broad = 1
    }
    if (rec && frc && (broad || paths == 0)) return 1
  }
  return 0
}
# Shell words of one line: RW[1..RN] raw text, RK[i] "w" word, "b" command
# boundary (an unquoted ; & | ( or ), or a standalone { or }), "r" redirection
# operator (its target is the next word). A ( right after $ stays in the word.
# With cm set, an unquoted word starting with # ends the line (a comment).
function rm_push(w) { RN++; RW[RN] = w; RK[RN] = (w == "{" || w == "}") ? "b" : "w" }
function rm_words(line, cm,   n, ch, i, c, q, w, inw, op) {
  RN = 0; n = split(line, ch, ""); w = ""; q = ""; inw = 0
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (q != "") {
      w = w c
      if (q == "\"" && c == "\\" && i < n) { i++; w = w ch[i]; continue }
      if (c == q) q = ""
      continue
    }
    if (cm && !inw && c == "#") break
    if (c == "\\") { w = w c; if (i < n) { i++; w = w ch[i] } inw = 1; continue }
    if (c == "\047" || c == "\"") { q = c; w = w c; inw = 1; continue }
    if (c == " " || c == "\t" || c == "\r") { if (inw) { rm_push(w); w = ""; inw = 0 } continue }
    if (c == "&" && i < n && ch[i + 1] == ">") {
      if (inw) { rm_push(w); w = ""; inw = 0 }
      i++; op = "&>"; while (i < n && ch[i + 1] ~ /[<>&|-]/) { i++; op = op ch[i] }
      RN++; RW[RN] = op; RK[RN] = "r"; continue
    }
    if (c == ")" || c == ";" || c == "&" || c == "|" || (c == "(" && !(inw && ch[i - 1] == "$"))) {
      if (inw) { rm_push(w); w = ""; inw = 0 }
      RN++; RW[RN] = c; RK[RN] = "b"; continue
    }
    if (c == "<" || c == ">") {
      op = ""
      if (inw && w ~ /^([0-9]+|&)$/) op = w
      else if (inw) rm_push(w)
      w = ""; inw = 0; op = op c
      while (i < n && ch[i + 1] ~ /[<>&|-]/) { i++; op = op ch[i] }
      RN++; RW[RN] = op; RK[RN] = "r"; continue
    }
    w = w c; inw = 1
  }
  if (inw) rm_push(w)
}
# hb: head_broad of the whole line. RMCD (an unsafe cd/pushd seen earlier in
# the text) persists across lines; G4L marks a line joined at backslash-newline.
function rm_scan(line, hb,   i, j, u, w, t, b, op, cmdpos, xa, cv, rec, frc, ops, bad, gb, dd, g4, lb, rel) {
  rm_words(line, 1)
  cmdpos = 1; xa = 0
  for (i = 1; i <= RN; i++) {
    if (RK[i] == "b") { cmdpos = 1; xa = 0; continue }
    if (RK[i] == "r") { if (i < RN && RK[i + 1] == "w") i++; continue }
    u = RW[i]; gsub(/[\\"\047]/, "", u)
    b = u; sub(/^.*\//, "", b)
    if (cmdpos && (u == "cd" || u == "pushd")) {
      t = ""
      for (j = i + 1; j <= RN && RK[j] == "w"; j++) {
        if (RW[j] ~ /^-[LPe@]$/) continue
        if (RW[j] == "--") { if (j < RN && RK[j + 1] == "w") t = RW[j + 1]; break }
        t = RW[j]; break
      }
      if (!cd_ok(t)) RMCD = 1
      cmdpos = 0; continue
    }
    # A command word holding an expansion ($x, r${E}m, $(which rm)).
    cv = cmdpos && u !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && u ~ /[$`]/
    if (b == "rm" || cv) {
      rec = 0; frc = 0; ops = 0; bad = 0; gb = 0; dd = 0; g4 = G4L; lb = 0; rel = 0
      for (j = i + 1; j <= RN; j++) {
        # { } and ( never start a command here: x(y), <( … ), a { b.
        if (RK[j] == "b") { if (RW[j] == "{" || RW[j] == "}" || RW[j] == "(") { g4 = 1; continue } break }
        if (RK[j] == "r") {
          op = RW[j]
          if (op ~ /^([0-9]*|&)(>|>>|<)$/ || (op ~ /^[0-9]*>&$/ && j < RN && RW[j + 1] ~ /^[0-9]+$/)) {
            if (j < RN && RK[j + 1] == "w") j++
            continue
          }
          # Not modelled: its next word is judged as an operand.
          g4 = 1; continue
        }
        w = RW[j]
        if (index(w, "\\;") || index(w, "\\&") || index(w, "\\|") || odd_bs(w)) g4 = 1
        u = w; gsub(/[\\"\047]/, "", u)
        if (u ~ /^--./) {
          if (length(u) >= 3 && index("--recursive", u) == 1) rec = 1
          if (length(u) >= 3 && index("--force", u) == 1) frc = 1
          continue
        }
        if (u ~ /^-./) { if (u ~ /[rR]/) rec = 1; if (u ~ /f/) frc = 1; continue }
        if (u == "-" || u == "--") continue
        ops++
        if (!specific_path(w)) { if (RMGIT) gb = 1; else bad = 1 }
        t = unquote(w)
        if (("/" t "/") ~ /\/\.\.\//) dd = 1
        if (tolower("/" t "/") ~ /\/\.git\//) gb = 1
        if (substr(t, 1, 1) != "/") rel = 1
        if (looks_broad(u)) lb = 1
      }
      if (rec && frc) {
        if (xa) return 3
        if (ops == 0 || dd) return 1
        if (bad && (hb || cv)) return 1
        if (g4 && (hb || lb)) return 1
        if (RMCD && rel) return 1
        if (gb) return 2
      }
      i = j - 1; continue
    }
    if (b == "xargs") xa = 1
    if (cmdpos && u !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && u !~ /^(sudo|env|command|builtin|exec|eval|nohup|time|nice|xargs|then|do|else|if|while|until|!)$/) cmdpos = 0
  }
  return 0
}
# The 8.0.3 regex shape `rm -<x>r<x>f<x> ` followed by . / ~ or $HOME, which
# also matched `farm -rf /`: denied unless every word after it, up to a
# command boundary or a comment, is on the allow-list.
function rm_legacy(l,   j, gb) {
  if (!match(l, /rm[ \t]+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*[ \t]+([.\/~]|[$]HOME)/)) return 0
  rm_words(substr(l, RSTART), 1); gb = 0
  for (j = 2; j <= RN && RK[j] != "b"; j++) {
    if (RK[j] == "r") { if (j < RN && RK[j + 1] == "w") j++; continue }
    if (RW[j] ~ /^-/) continue
    if (!specific_path(RW[j])) { if (!RMGIT) return 1; gb = 1 }
  }
  return gb ? 2 : 0
}
function rm_broad(line,   crude, v, hb) {
  crude = line; gsub(/[\\"\047]/, "", crude)
  if (crude !~ /rm|[$]|cd|pushd/) return 0
  G4L = index(line, "MTKBSNL=1") > 0
  hb = (crude ~ /rm/) ? head_broad(line) : 0
  gsub(/`/, " ( ", crude)
  v = rm_scan(line, hb); if (v) return v
  v = rm_scan(crude, hb); if (v) return v
  return rm_legacy(line)
}
'
# The working directory, for cd_ok above (a cd into it is as safe as none).
MTK_GATE_CWD="$PWD"
export MTK_GATE_CWD

# MTK_SUBST_SPLIT_AWK: one segment holding $( … ) or backticks in, one line per
# substitution body out (innermost first), then the outer text with each
# substitution replaced by the word $MTKS. Each line is judged on its own, so
# `out=$(grep …)` is a grep and `grep "$(<delete>)"` still yields the delete,
# while the outer text keeps a non-literal marker where the substitution was:
# `rm -rf ./build/$(…)` stays an rm of a non-literal path, and `$(…) -rf /`
# keeps its command position. Quotes are not honoured: splitting can only
# produce more text to judge, never less. Linear in the segment length.
MTK_SUBST_SPLIT_AWK='
{
  s = $0; n = split(s, ch, ""); top = 0; buf[0] = ""; kind[0] = "o"; dep[0] = 0; run = 1
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (c == "$" && i < n && ch[i + 1] == "(") {
      buf[top] = buf[top] substr(s, run, i - run)
      top++; buf[top] = ""; kind[top] = "s"; dep[top] = 0; i++; run = i + 1; continue
    }
    if (c == "`") {
      buf[top] = buf[top] substr(s, run, i - run); run = i + 1
      if (kind[top] == "b") { print buf[top]; top--; buf[top] = buf[top] "$MTKS" }
      else { top++; buf[top] = ""; kind[top] = "b"; dep[top] = 0 }
      continue
    }
    if (c == "(") { dep[top]++; continue }
    if (c == ")") {
      if (dep[top] > 0) { dep[top]--; continue }
      if (kind[top] == "s") {
        buf[top] = buf[top] substr(s, run, i - run); run = i + 1
        print buf[top]; top--; buf[top] = buf[top] "$MTKS"
      }
      continue
    }
  }
  buf[top] = buf[top] substr(s, run)
  while (top > 0) { print buf[top]; top--; buf[top] = buf[top] "$MTKS" }
  print buf[0]
}'

# MTK_SEG_SPLIT_AWK: the whole command in, one line per segment out, each
# prefixed with `:`, then a line `E` (so a reader can tell a finished split
# from a failed one; no segment line can equal it). One process for the whole
# command: forking a splitter per segment cost ~7.5 ms each.
#   - Segments are cut at ; | and &, except the redirect spellings &> >& <&
#     and >| (cutting `x &>/dev/null /` before its last word hid an operand).
#   - A line with an escaped separator (x\;y) is also emitted cut only at
#     unescaped ones, so the word the shell sees is judged too.
#   - Lines joined at backslash-newline are also emitted as the one line the
#     shell sees, each segment prefixed `MTKBSNL=1 ` (an assignment word every
#     judge peels; rm_broad reads it as "joined").
#   - Unless RAW is set, a segment holding $( … ) or backticks is emitted as
#     each substitution body (innermost first) and then the outer text with
#     each substitution replaced by the word $MTKS: `out=$(grep …)` is a grep,
#     `grep "$(<delete>)"` still yields the delete, and `rm -rf ./b/$(…)` stays
#     an rm of a non-literal path. Quotes are not honoured: splitting can only
#     produce more text to judge, never less.
# Linear in the text.
MTK_SEG_SPLIT_AWK='
function sub_out(s, pre,   n, ch, top, buf, kind, dep, run, i, c) {
  n = split(s, ch, ""); top = 0; buf[0] = ""; kind[0] = "o"; dep[0] = 0; run = 1
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (c == "$" && i < n && ch[i + 1] == "(") {
      buf[top] = buf[top] substr(s, run, i - run)
      top++; buf[top] = ""; kind[top] = "s"; dep[top] = 0; i++; run = i + 1; continue
    }
    if (c == "`") {
      buf[top] = buf[top] substr(s, run, i - run); run = i + 1
      if (kind[top] == "b") { print ":" pre buf[top]; top--; buf[top] = buf[top] "$MTKS" }
      else { top++; buf[top] = ""; kind[top] = "b"; dep[top] = 0 }
      continue
    }
    if (c == "(") { dep[top]++; continue }
    if (c == ")") {
      if (dep[top] > 0) { dep[top]--; continue }
      if (kind[top] == "s") {
        buf[top] = buf[top] substr(s, run, i - run); run = i + 1
        print ":" pre buf[top]; top--; buf[top] = buf[top] "$MTKS"
      }
      continue
    }
  }
  buf[top] = buf[top] substr(s, run)
  while (top > 0) { print ":" pre buf[top]; top--; buf[top] = buf[top] "$MTKS" }
  print ":" pre buf[0]
}
function emit(s, pre) {
  if (!RAW && (index(s, "$(") || index(s, "`"))) sub_out(s, pre)
  else print ":" pre s
}
function seg_split(l, esc, pre,   n, ch, i, c, p, run) {
  n = split(l, ch, ""); run = 1; p = ""
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (esc && c == "\\") { i++; p = ""; continue }
    if (c == ";" || (c == "|" && p != ">") || (c == "&" && p != "<" && p != ">" && ch[i + 1] != ">")) {
      emit(substr(l, run, i - run), pre); run = i + 1
    }
    p = c
  }
  emit(substr(l, run), pre)
}
function has_esc(l) { return index(l, "\\;") || index(l, "\\&") || index(l, "\\|") }
function odd_tail(l,   n, k) {
  n = length(l); k = 0
  while (n > 0 && substr(l, n, 1) == "\\") { k++; n-- }
  return k % 2
}
{
  l = $0
  seg_split(l, 0, "")
  if (has_esc(l)) seg_split(l, 1, "")
  if (odd_tail(l)) { J = J substr(l, 1, length(l) - 1); NJ = 1; next }
  if (NJ) {
    J = J l; seg_split(J, 0, "MTKBSNL=1 ")
    if (has_esc(J)) seg_split(J, 1, "MTKBSNL=1 ")
    J = ""; NJ = 0
  }
}
END {
  if (NJ) { seg_split(J, 0, "MTKBSNL=1 "); if (has_esc(J)) seg_split(J, 1, "MTKBSNL=1 ") }
  print "E"
}'

# Split $2 (MTK_SEG_SPLIT_AWK) and run judge $1 on every segment, printing
# what the judge prints. Checks the deadline before each segment; prints
# MTK_GATE_LATE instead once it has passed, and MTK_GATE_SPLITERR when the
# splitter did not finish. The callers deny on either marker.
mtk_bs_judge_text() {
  local _judge="$1" _seg _end=0
  while IFS= read -r _seg; do
    case "$_seg" in
      :*) ;;
      E) _end=1; break ;;
      *) break ;;
    esac
    if [ "$SECONDS" -ge "$MTK_GATE_DEADLINE" ]; then printf '%s\n' "$MTK_GATE_LATE"; return 0; fi
    "$_judge" "${_seg#:}"
  done < <(printf '%s\n' "${2-}" | awk -v RAW="${MTK_SPLIT_RAW:-0}" "$MTK_SEG_SPLIT_AWK" 2>/dev/null)
  [ "$_end" = 1 ] || printf '%s\n' "$MTK_GATE_SPLITERR"
}

# Every segment as it is, no exemption (text piped into a shell executes).
mtk_bs_print_seg() { printf '%s\n' "$1"; }

# Has judging run past the deadline? (See MTK_GATE_DEADLINE.)
mtk_gate_late() { [ "$SECONDS" -ge "$MTK_GATE_DEADLINE" ]; }

# Reduce a command to the parts that could actually EXECUTE something.
#
# A search or print command MENTIONS text, it does not run it: `grep -rn '<delete>'`
# and `echo "never run <delete>"` are safe, and denying them is expensive — a
# PreToolUse deny forces the model to re-plan and re-issue, costing a whole extra
# turn. Split on the shell's own separators and drop segments whose command word is
# a read-only tool; everything else is judged exactly as before.
#
# The command word is found AFTER peeling what the shell itself would peel: leading
# `VAR=value` assignments, control words (`if grep …`, `do grep …`, `! grep …`),
# pass-through wrappers (`xargs grep`, `time grep`, `find … -exec grep`), read-only
# `git` subcommands (`git grep`, `git log`), and `bash -c "<inner>"` (the inner text
# is judged as its own command). A 2026-08 field run was blocked on
# `for f in …; do grep -H '<delete>' "$f"; done` — the grep was read-only, the
# segment's first word was `do`.
#
# Command substitutions are judged by RECURSION, never exempted wholesale: `$(` `)`
# and backticks become segment boundaries, so `out=$(grep -c '<delete>' f)` is a
# grep, while `grep "$(<delete>)"` still yields the inner `<delete>` as its own
# segment. Splitting can only produce MORE fragments to judge, never fewer — the
# same argument that already applies to `|` cutting a quoted regex in half.
mtk_bs_readonly_word() {
  # A long word is never a tool name, and `##*/` on it is quadratic.
  [ "${#1}" -le 256 ] || return 1
  case "${1##*/}" in
    grep|egrep|fgrep|rg|ack|ag|echo|printf|cat|head|tail|less|more|strings|wc| \
    awk|gawk|mawk|nawk|sort|uniq|cut|tr|diff|comm|jq|ls|stat|file|test|'['|true|false|type|which) return 0 ;;
  esac
  return 1
}

# Drop the first word of $rest (and its leading whitespace); refresh $word.
# Each call copies $rest, so the judges below stop peeling after
# MTK_GATE_MAX_PREFIX words and judge the whole segment instead: a 32 KB chain
# of `time ` or `xargs -0 ` costs one bounded pass, not one copy per word.
mtk_bs_shift_word() {
  _peel=$((_peel + 1))
  rest="${rest#"$word"}"; rest="${rest#"${rest%%[![:space:]]*}"}"; word="${rest%%[[:space:]]*}"
}

# One segment holding $( … ) or backticks: judge each substitution body and the
# outer text on its own (MTK_SUBST_SPLIT_AWK). $1 is the judge to recurse into.
# When awk fails the segment is judged whole: nothing is ever dropped.
mtk_bs_split_subst() {
  local _judge="$1" _seg="$2" _out _inner
  if ! _out="$(printf '%s\n' "$_seg" | awk "$MTK_SUBST_SPLIT_AWK")"; then
    printf '%s\n' "$_seg"; return 0
  fi
  while IFS= read -r _inner || [ -n "$_inner" ]; do
    case "$_inner" in *[![:space:]]*) "$_judge" "$_inner" ;; esac
  done <<<"$_out"
}

# One separator-free segment in, the text to judge out (nothing if exempt).
mtk_bs_judge_segment() {
  # _peel is inherited (dynamic scope) by the find -exec and bash -c recursion,
  # so nesting counts toward the same bound.
  local seg="$1" rest word inner _peel="${_peel:-0}"
  case "$seg" in
    *'$('*|*'`'*) mtk_bs_split_subst mtk_bs_judge_segment "$seg"; return 0 ;;
  esac
  rest="${seg#"${seg%%[![:space:]]*}"}"
  word="${rest%%[[:space:]]*}"
  # Peel assignments, control words, and wrappers until a real command word remains.
  while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
    case "$word" in
      *=*|do|done|then|else|elif|fi|if|while|until|'!'|'{'|'}'|'('|')'|time|nice|nohup|command|builtin|exec)
        mtk_bs_shift_word ;;
      xargs)
        mtk_bs_shift_word
        # Drop xargs' own flags; -I/-n/-P/-L/-d/-s/-E take a separate argument.
        while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
          case "$word" in
            -I|-n|-P|-L|-d|-s|-E) mtk_bs_shift_word; mtk_bs_shift_word ;;
            -*) mtk_bs_shift_word ;;
            *) break ;;
          esac
        done ;;
      git)
        mtk_bs_shift_word
        while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
          case "$word" in
            -C|-c) mtk_bs_shift_word; mtk_bs_shift_word ;;
            --no-pager|--paginate|-p) mtk_bs_shift_word ;;
            *) break ;;
          esac
        done
        [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ] || break
        case "$word" in
          grep|log|diff|show|status|blame|ls-files|rev-parse|describe|shortlog|cat-file|rev-list|name-rev) return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
      find)
        # `find … -exec <cmd> …`: judge <cmd>. `-delete` and anything else: judge whole.
        # A regex, not ${rest#* -exec}: that prefix match is quadratic in bash.
        if [[ "$rest" =~ [[:space:]]-exec(dir)?[[:space:]](.*)$ ]]; then
          _peel=$((_peel + 1)); mtk_bs_judge_segment "${BASH_REMATCH[2]}"; return 0
        fi
        printf '%s\n' "$seg"; return 0 ;;
      bash|sh|zsh|dash|ksh)
        mtk_bs_shift_word
        case "$word" in
          -c|-lc|-ec)
            inner="${rest#"$word"}"; inner="${inner#"${inner%%[![:space:]]*}"}"
            # Strip one layer of surrounding quotes and judge the inner command text.
            case "$inner" in
              \"*\") inner="${inner#\"}"; inner="${inner%\"}" ;;
              \'*\') inner="${inner#\'}"; inner="${inner%\'}" ;;
            esac
            # Shells nested past MTK_GATE_MAX_NEST: not judged, denied.
            local _mtk_cdepth=$(( ${_mtk_cdepth:-0} + 1 ))
            if [ "$_mtk_cdepth" -gt "$MTK_GATE_MAX_NEST" ]; then printf '%s\n' "$MTK_GATE_LATE"; return 0; fi
            # Inner text with no separator, substitution or backslash is one
            # segment: judge it here, without a splitter process.
            case "$inner" in
              *';'*|*'|'*|*'&'*|*'`'*|*'\'*|*'$('*) mtk_bs_judge_text mtk_bs_judge_segment "$inner" ;;
              *) mtk_bs_judge_segment "$inner" ;;
            esac
            return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
      sed)
        # sed is a filter unless it edits in place.
        case " $rest " in
          *' -i'*|*' --in-place'*) printf '%s\n' "$seg" ;;
        esac
        return 0 ;;
      *) break ;;
    esac
  done
  # Past the peel bound: judge the whole segment (never exempt it).
  if [ "$_peel" -gt "$MTK_GATE_MAX_PREFIX" ]; then printf '%s\n' "$seg"; return 0; fi
  [ -n "$word" ] || return 0
  mtk_bs_readonly_word "$word" || printf '%s\n' "$seg"
}

# Segments are cut by MTK_SEG_SPLIT_AWK (one process for the whole command);
# the output ends in a marker line when the deadline passed or the split failed.
mtk_bs_executable_text() { mtk_bs_judge_text mtk_bs_judge_segment "${1-}"; }

# S3.17: every match below feeds grep -q through process substitution, never a
# pipe. grep -q exits on its first match, the producer takes SIGPIPE (141), and
# pipefail turns that *success* into a non-zero pipeline — so `if <pipeline>` reads
# FALSE and the guard FAILS OPEN on exactly the destructive commands it exists to
# block. Process-substitution exit status is ignored, so the match stands on its own.
# The destructive-SQL pattern lives in one place so the command text and any file the
# command executes are judged by identical rules.
mtk_bs_has_destructive_sql() {
  grep -qiE '(DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\S+\s*;?\s*$)' \
    <(printf '%s' "${1-}")
}

# Files this command would execute or feed to a database client.
#
# Matching the command text alone is not enough: `bash rebuild.sh` and `psql -f drop.sql`
# contain no SQL themselves, so a DROP SCHEMA sitting in the file sails straight through.
# That is not hypothetical — it is how one got past this gate on 2026-08-10 minutes after
# the same statements had been blocked when typed inline.
# Only paths the command actually runs count. Matching every .sh/.sql path mentioned
# anywhere would block `git add rebuild.sh` and `cat drop.sql`, which execute nothing —
# reading and staging a file is not running it.
mtk_bs_referenced_files() {
  local _cmd="${1-}"
  {
    # An interpreter runs it: bash x.sh, sh ./x.sh, source x.sh, . x.sh
    printf '%s' "$_cmd" | grep -oiE '(^|[;&|(]|[[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[A-Za-z0-9_.:@~/+-]+' || true
    # It is executed directly: ./x.sh, /opt/x.bash. Anchored to command position — after a
    # separator, not after a space — because `git add /tmp/x.sh` passes an absolute path as an
    # argument and that is not execution.
    printf '%s' "$_cmd" | grep -oE '(^|[;&|(])[[:space:]]*\.?/[A-Za-z0-9_.:@~/+-]+\.(sh|bash|zsh)' || true
    # A database client reads it: psql -f x.sql, mysql --file=x.sql
    printf '%s' "$_cmd" | grep -oiE '(-f|--file)[=[:space:]]+[A-Za-z0-9_.:@~/+-]+' || true
  } 2>/dev/null \
    | grep -oE '[A-Za-z0-9_.:@~/+-]+$' \
    | sort -u
}

# A file under the repo's own tests/ tree carries destructive statements as fixtures, not
# as work to run: tests/hooks/test-security-gate.sh asserts that `DROP SCHEMA` is blocked,
# so it must contain the string to test for it. Scanning it makes the gate block its own
# regression suite — `bash tests/hooks/test-security-gate.sh` was denied outright. Scoped
# to tests/ inside this repo and resolved by device+inode (S1.17), so a destructive script
# anywhere else, or a tests/ path in some other checkout, is still read and still caught.
mtk_bs_is_repo_test_file() {
  local _f="${1-}" _abs _root _rel
  _root="$(mtk_repo_root 2>/dev/null || true)"
  [ -n "$_root" ] || return 1
  case "$_f" in
    /*) _abs="$_f" ;;
    *)  _abs="$PWD/$_f" ;;
  esac
  _rel="$(mtk_repo_relative_path "$_abs" "$_root" 2>/dev/null || true)"
  [ -n "$_rel" ] || return 1
  case "$_rel" in tests/*) return 0 ;; esac
  return 1
}

# Reason the base gate would have denied `text`, printed; returns 0 on a hit
# and 1 when the base gate would have allowed it.
mtk_backstop_reason() {
  local text="${1-}" exec_text ref body
  exec_text="$(mtk_bs_executable_text "$text")"
  case "$exec_text" in
    *"$MTK_GATE_LATE"*) printf '%s\n' "$MTK_GATE_LATE_REASON"; return 0 ;;
    *"$MTK_GATE_SPLITERR"*) printf '%s\n' "$MTK_GATE_SPLITERR_REASON"; return 0 ;;
  esac
  if mtk_bs_has_destructive_sql "$exec_text"; then
    printf 'Destructive database operation detected. Use a migration instead.\n'; return 0
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if mtk_gate_late; then printf '%s\n' "$MTK_GATE_LATE_REASON"; return 0; fi
    [ -f "$ref" ] || continue
    mtk_bs_is_repo_test_file "$ref" && continue
    case "$ref" in
      *.sql|*.SQL) body="$(head -c 200000 "$ref" 2>/dev/null || true)" ;;
      *)           body="$(head -c 200000 "$ref" 2>/dev/null | sed 's/[[:space:]]*#.*$//' || true)" ;;
    esac
    if mtk_bs_has_destructive_sql "$body"; then
      printf 'Destructive database operation found in %s. Use a migration instead.\n' "$ref"; return 0
    fi
  done <<MTK_BS_REFS
$(mtk_bs_referenced_files "$text")
MTK_BS_REFS
  if grep -qE 'git\s+push\s+.*--(force|force-with-lease)\s+.*\b(main|master)\b' <<<"$exec_text"; then
    printf 'Force push to main/master is not allowed.\n'; return 0
  fi
  # Prefilter only: quotes and backslashes can spell rm without the letters
  # being adjacent (r''m, r\m), so any of them also sends the text to awk.
  case "$exec_text" in
    *rm*|*'$'*|*[\\\'\"]*)
      # Every operand of every recursive force delete is judged by rm_broad.
      # Status 1 is "clean"; anything else, an awk failure included, denies.
      local rc=0
      awk "$MTK_RM_AWK"'
        { v = rm_broad($0); if (v) { hit = v; exit } }
        END { exit (hit ? 10 + hit : 1) }
      ' <<<"$exec_text" || rc=$?
      case "$rc" in
        1) ;;
        12) printf '%s\n' "$MTK_RM_GIT_REASON"; return 0 ;;
        13) printf '%s\n' "$MTK_RM_XARGS_REASON"; return 0 ;;
        *) printf '%s\n' "$MTK_RM_DENY_REASON"; return 0 ;;
      esac ;;
  esac
  return 1
}
