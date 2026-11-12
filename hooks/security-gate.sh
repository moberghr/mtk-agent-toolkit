#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse security gate for Bash commands.
# Receives JSON on stdin with tool_name, tool_input, etc.
# Exit 0 = allow, exit 2 = block.
#
# The deny list in settings.json handles exact pattern matches.
# This script catches destructive patterns in any spelling deny rules miss:
# - force pushes (-f, trailing --force, git -C <dir> push, +refspec); the
#   --force-with-lease alternative is allowed
# - recursive force deletes (rm -rf / -fr / -r -f, xargs rm -rf), git reset
#   --hard, git clean -f…, dotnet ef database drop
# - a download piped into a shell (curl … | sh)
# - destructive SQL, typed inline or inside a script/.sql file the command runs
# Text that only MENTIONS such a command — a commit message, a PR body, a
# heredoc written to a file — is stripped before judging (mtk_strip_inert_text).
# Last, a command that can hang on an interactive prompt (`gh pr merge` with no
# delete-branch decision, a prompt-capable command piped into tail/head) is
# denied (S4.12; the former interactive-guard.sh, off with MTK_INTERACTIVE_GUARD=0).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
mtk_hook_seen security-gate.sh

INPUT="$(mtk_read_payload)"

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")

# If this is not a Bash payload, ignore it.
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Every deny below goes through gate_deny. GATE_HINT is set once the command is
# known (see below).
GATE_HINT=""
gate_deny() { mtk_deny "${1}${GATE_HINT}"; }

# Size caps, checked before anything is judged. Judging grows with length and
# costs a few ms per segment that holds a command substitution (measured
# 2026-11-11 on macOS bash 3.2: ~4.5 ms per `$(…)` segment and ~1.5 s for an
# 84 KB heredoc at load 4). The hook has a 5 s timeout, after which the harness
# treats it as non-blocking, so a long enough command with a destructive tail
# would run unjudged. Anything over a cap is denied at once instead. Bytes are
# measured on the raw payload and command (extracting and stripping text are
# themselves superlinear); segments and substitutions on the stripped text, so
# a PR body full of backticks does not count. Within the caps every judge is
# linear in the text (the segment peel is bounded by MTK_GATE_MAX_PREFIX, the
# awk token checks visit each word a fixed number of times), so the worst
# admitted 32 KB command costs about 1 s of CPU (user+sys, measured 2026-11-11);
# wall-clock time on a loaded host is higher by the load factor.
MTK_GATE_MAX_BYTES="${MTK_SECURITY_GATE_MAX_BYTES:-}"
case "$MTK_GATE_MAX_BYTES" in ''|*[!0-9]*|0*) MTK_GATE_MAX_BYTES=32768 ;; esac
MTK_GATE_MAX_SEGMENTS="${MTK_SECURITY_GATE_MAX_SEGMENTS:-}"
case "$MTK_GATE_MAX_SEGMENTS" in ''|*[!0-9]*|0*) MTK_GATE_MAX_SEGMENTS=2500 ;; esac
MTK_GATE_MAX_SUBST="${MTK_SECURITY_GATE_MAX_SUBST:-}"
case "$MTK_GATE_MAX_SUBST" in ''|*[!0-9]*|0*) MTK_GATE_MAX_SUBST=1024 ;; esac
# `bash -c` / `sh -c` / `-lc` / `-ec` (any of bash sh zsh dash ksh): the inner
# text is judged as a command of its own, and when it holds a separator or a
# substitution that costs a splitter process (~3 ms). Counted textually.
MTK_GATE_MAX_SHELL_C="${MTK_SECURITY_GATE_MAX_SHELL_C:-}"
case "$MTK_GATE_MAX_SHELL_C" in ''|*[!0-9]*|0*) MTK_GATE_MAX_SHELL_C=128 ;; esac

gate_too_long() { # $1 what was counted, $2 count, $3 limit
  gate_deny "BLOCKED: this command is too long for the security gate to judge in time ($1: $2, limit $3). Split it into smaller commands, or write it to a script file with the Write tool and run that."
}
# Byte length without a subshell: ${#var} counts bytes under the C locale.
_mtk_byte_len() { local LC_ALL=C; MTK_LEN=${#1}; }

# The payload first: extracting the command from it is quadratic (~1 s for a
# 140 KB payload). JSON escaping at most doubles a command's text; 8 KB is room
# for the payload's other fields. The command itself is held to the cap below.
_mtk_byte_len "$INPUT"
MTK_GATE_MAX_PAYLOAD=$(( MTK_GATE_MAX_BYTES * 2 + 8192 ))
[ "$MTK_LEN" -le "$MTK_GATE_MAX_PAYLOAD" ] || gate_too_long "payload bytes" "$MTK_LEN" "$MTK_GATE_MAX_PAYLOAD"

COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")

# Fail closed for Bash payloads we cannot parse.
if [ -z "$COMMAND" ]; then
  mtk_deny "BLOCKED: Unable to parse Bash command from hook payload. Re-run the command after fixing the hook payload shape."
fi

# When the command carries a heredoc, the likely intent is writing a file, and
# the Write tool does that without passing the content through this gate.
case "$COMMAND" in
  *'<<<'*) ;;
  *'<<'*) GATE_HINT=" If this text is file content, write the file with the Write tool instead of a Bash heredoc." ;;
esac

_mtk_byte_len "$COMMAND"
[ "$MTK_LEN" -le "$MTK_GATE_MAX_BYTES" ] || gate_too_long bytes "$MTK_LEN" "$MTK_GATE_MAX_BYTES"

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
mtk_readonly_word() {
  # A long word is never a tool name, and `##*/` on it is quadratic.
  [ "${#1}" -le 256 ] || return 1
  case "${1##*/}" in
    grep|egrep|fgrep|rg|ack|ag|echo|printf|cat|head|tail|less|more|strings|wc| \
    sort|uniq|cut|tr|diff|comm|jq|ls|stat|file|test|'['|true|false|type|which) return 0 ;;
  esac
  return 1
}

# Drop the first word of $rest (and its leading whitespace); refresh $word.
# Each call copies $rest, so peeling stops after MTK_GATE_MAX_PREFIX words
# (hooks/lib/gate-backstop.sh) and the whole segment is judged instead: a 32 KB
# chain of `time ` or `xargs -0 ` costs one bounded pass, not one copy per word.
mtk_shift_word() {
  _peel=$((_peel + 1))
  rest="${rest#"$word"}"; rest="${rest#"${rest%%[![:space:]]*}"}"; word="${rest%%[[:space:]]*}"
}

# One separator-free segment in, the text to judge out (nothing if exempt).
mtk_judge_segment() {
  # _peel is inherited (dynamic scope) by the find -exec and bash -c recursion,
  # so nesting counts toward the same bound.
  local seg="$1" rest word inner _peel="${_peel:-0}"
  case "$seg" in
    *'$('*|*'`'*) mtk_bs_split_subst mtk_judge_segment "$seg"; return 0 ;;
  esac
  rest="${seg#"${seg%%[![:space:]]*}"}"
  word="${rest%%[[:space:]]*}"
  # Peel assignments, control words, and wrappers until a real command word remains.
  while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
    case "$word" in
      *=*|do|done|then|else|elif|fi|if|while|until|'!'|'{'|'}'|'('|')'|time|nice|nohup|command|builtin|exec)
        mtk_shift_word ;;
      xargs)
        mtk_shift_word
        # Drop xargs' own flags; -I/-n/-P/-L/-d/-s/-E take a separate argument.
        while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
          case "$word" in
            -I|-n|-P|-L|-d|-s|-E) mtk_shift_word; mtk_shift_word ;;
            -*) mtk_shift_word ;;
            *) break ;;
          esac
        done ;;
      git)
        mtk_shift_word
        while [ -n "$word" ] && [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ]; do
          case "$word" in
            -C|-c) mtk_shift_word; mtk_shift_word ;;
            --no-pager|--paginate|-p) mtk_shift_word ;;
            *) break ;;
          esac
        done
        [ "$_peel" -le "$MTK_GATE_MAX_PREFIX" ] || break
        case "$word" in
          grep|log|diff|show|status|blame|ls-files|rev-parse|describe|shortlog|cat-file|rev-list|name-rev) return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
      find)
        # A find that deletes (-delete, -exec rm) is judged whole, so the find
        # check sees it. `find … -exec <cmd> …` otherwise: judge <cmd>. A
        # regex, not ${rest#* -exec}: that prefix match is quadratic in bash.
        if [[ " $rest " =~ [[:space:]]-delete[[:space:]] ]] \
          || [[ " $rest " =~ [[:space:]]-(exec|execdir|ok|okdir)[[:space:]]+([^[:space:]]*/)?rm[[:space:]] ]]; then
          printf '%s\n' "$seg"; return 0
        fi
        if [[ "$rest" =~ [[:space:]]-exec(dir)?[[:space:]](.*)$ ]]; then
          _peel=$((_peel + 1)); mtk_judge_segment "${BASH_REMATCH[2]}"; return 0
        fi
        printf '%s\n' "$seg"; return 0 ;;
      bash|sh|zsh|dash|ksh)
        mtk_shift_word
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
              *';'*|*'|'*|*'&'*|*'`'*|*'\'*|*'$('*) mtk_bs_judge_text mtk_judge_segment "$inner" ;;
              *) mtk_judge_segment "$inner" ;;
            esac
            return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
      awk|gawk|mawk|nawk)
        # awk is a filter unless its program shells out: system("…") runs a
        # command, so it is not read-only then. (`print | "cmd"` already splits
        # at the `|` and leaves the command text to be judged.)
        case "$rest" in
          *system*) printf '%s\n' "$seg" ;;
        esac
        return 0 ;;
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
  mtk_readonly_word "$word" || printf '%s\n' "$seg"
}

# Segments are cut by MTK_SEG_SPLIT_AWK (hooks/lib/gate-backstop.sh, one
# process for the whole command); the output ends in a marker line when the
# deadline passed or the split failed, and the caller denies on either.
mtk_executable_text() { mtk_bs_judge_text mtk_judge_segment "${1-}"; }

# Remove text the command carries but never executes, before anything is judged.
# Two passes, both POSIX awk (macOS has no gawk):
#
#   1. mtk_strip_inert_heredocs drops a heredoc body ONLY when it feeds a git
#      or gh message directly:
#        - `git commit … -F - <<EOF` and `gh … --body-file - <<EOF` (stdin sinks)
#        - `"$(cat <<EOF` as the quoted value of a git/gh message flag
#      A heredoc written to a file is never stripped, whatever the extension:
#      every "only a doc" exemption was a way to write a script and run it.
#      File content belongs in the Write tool, which this gate does not judge.
#      An unquoted delimiter whose body contains `$(` or a backtick is kept: the
#      shell expands it. Every other body — a script written to x.sh, SQL for
#      psql, input for `while read c; do $c; done`, `. /dev/stdin` — is kept and
#      judged. Openers are recognised only in code: never inside quotes, a
#      comment or $(( arithmetic )). An unterminated delimiter keeps everything:
#      dropping "the rest of the command" is how a false opener used to hide an
#      rm that followed it.
#   2. mtk_strip_message_values drops the value of a message flag: in a
#      `git commit` segment -m/--message (text) and -F/--file (path); in a gh
#      segment --body/-b, --title/-t (text) and --body-file/-F (path). A
#      double-quoted value containing `$(` or a backtick is kept: the
#      substitution inside it executes.
#
# A PR body that says "never force-push" or a commit that names a destructive
# statement is prose; blocking it costs a full re-plan turn and teaches the
# model to reword its messages instead of trusting the gate.
mtk_strip_inert_heredocs() {
  awk '
    function linestart(i,   k) { k = i - 1; while (k >= 1 && substr(buf, k, 1) != "\n") k--; return k + 1 }
    # Classify the opener line L for delimiter d: 1 stdin message sink,
    # 3 message substitution, 0 anything else (kept and judged).
    function sink(L, d,   dq, w, s2, pth) {
      SINKPATH = ""
      dq = "<<-?[ \t]*(\047" d "\047|\"" d "\"|\\\\?" d ")[ \t]*"
      w = "[^ \t;&|<>`$()]+"
      s2 = "([^;&|<>`$()\"\047]|\"[^\"`$]*\"|\047[^\047]*\047)*"
      if (L ~ ("^[ \t]*git([ \t]+-[Cc][ \t]+" w ")*[ \t]+commit([ \t]+" s2 ")?[ \t]+(-F|--file)([ \t]+|=)-[ \t]+" dq "$")) return 1
      if (L ~ ("^[ \t]*gh([ \t]+" s2 ")?[ \t]+(--body-file|-F)([ \t]+|=)-[ \t]+" dq "$")) return 1
      if (L ~ ("^[ \t]*(git|gh)([ \t]+" s2 ")?[ \t]+(-m|--message|--body|-b|--notes|-n|--title|-t)([ \t]+|=)\"[$][(]cat[ \t]+" dq "$")) return 3
      return 0
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf); i = 1; top = 0; st[0] = "code"; np = 0; ndel = 0
      while (i <= n) {
        c = substr(buf, i, 1); m = st[top]
        if (m == "sq") { if (c == "\047") top--; i++; continue }
        if (m == "comment") { if (c == "\n") { top--; continue } i++; continue }
        if (m == "arith") {
          if (c == "(") ad[top]++
          else if (c == ")") { if (ad[top] > 0) ad[top]--; else { top--; if (substr(buf, i + 1, 1) == ")") i++ } }
          i++; continue
        }
        if (m == "dq") {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { top--; i++; continue }
          if (c == "$" && substr(buf, i + 1, 2) == "((") { st[++top] = "arith"; ad[top] = 0; i += 3; continue }
          if (c == "$" && substr(buf, i + 1, 1) == "(") { st[++top] = "subst"; i += 2; continue }
          if (c == "`") { st[++top] = "bt"; i++; continue }
          i++; continue
        }
        # code, subst, paren, bt
        if (c == "\\") { i += 2; continue }
        if (c == "\047") { st[++top] = "sq"; i++; continue }
        if (c == "\"") { st[++top] = "dq"; i++; continue }
        if (c == "`") { if (m == "bt") top--; else st[++top] = "bt"; i++; continue }
        if (c == "#" && (i == 1 || substr(buf, i - 1, 1) ~ /[ \t\n;&|(]/)) { st[++top] = "comment"; i++; continue }
        if ((c == "$" && substr(buf, i + 1, 2) == "((") || (c == "(" && substr(buf, i + 1, 1) == "(")) {
          st[++top] = "arith"; ad[top] = 0; i += (c == "$") ? 3 : 2; continue
        }
        if (c == "$" && substr(buf, i + 1, 1) == "(") { st[++top] = "subst"; i += 2; continue }
        if (c == "(") { st[++top] = "paren"; i++; continue }
        if (c == ")") { if (m == "subst" || m == "paren") top--; i++; continue }
        if (c == "<" && substr(buf, i + 1, 1) == "<" && substr(buf, i + 2, 1) != "<" && (i == 1 || substr(buf, i - 1, 1) != "<")) {
          j = i + 2; dash = 0
          if (substr(buf, j, 1) == "-") { dash = 1; j++ }
          while (substr(buf, j, 1) ~ /[ \t]/) j++
          qc = substr(buf, j, 1); quoted = 0
          if (qc == "\047" || qc == "\"") { quoted = 1; j++ } else if (qc == "\\") { quoted = 1; j++ }
          k = j; while (substr(buf, k, 1) ~ /[A-Za-z0-9_]/) k++
          if (k > j) {
            np++; pend[np] = substr(buf, j, k - j); ptab[np] = dash; pq[np] = quoted
            if (quoted && (qc == "\047" || qc == "\"")) k++
            i = k; continue
          }
          i += 2; continue
        }
        if (c == "\n" && np > 0) {
          ls = linestart(i); L = substr(buf, ls, i - ls)
          pos = i + 1; ok = 1
          for (h = 1; h <= np; h++) {
            bs[h] = pos; found = 0
            while (pos <= n) {
              e = index(substr(buf, pos), "\n"); e = (e == 0) ? n + 1 : pos + e - 1
              ln = substr(buf, pos, e - pos); tl = ln
              if (ptab[h]) sub(/^\t+/, "", tl)
              if (tl == pend[h]) { be[h] = pos - 1; te[h] = e; pos = e + 1; found = 1; break }
              pos = e + 1
            }
            if (!found) { ok = 0; break }
          }
          if (!ok) break
          if (np == 1) {
            kind = sink(L, pend[1])
            body = substr(buf, bs[1], be[1] - bs[1] + 1)
            if (!pq[1] && (index(body, "$(") || index(body, "`"))) kind = 0
            if (kind == 3) {
              nx = substr(buf, te[1] + 1); sub(/\n.*/, "", nx)
              if (nx !~ /^[ \t]*\)"/) kind = 0
            }
            if (kind) { ndel++; ds[ndel] = bs[1]; de[ndel] = te[1] }
          }
          np = 0; i = pos; continue
        }
        i++
      }
      out = ""; from = 1
      for (d = 1; d <= ndel; d++) { out = out substr(buf, from, ds[d] - from); from = de[d] + 1 }
      out = out substr(buf, from)
      printf "%s", out
    }
  ' <<<"${1-}"
}

mtk_strip_message_values() {
  awk '
    # tool: "git" until `commit` is seen, then "commit"; "gh"; "" otherwise.
    function endword(  b) {
      if (cur == "") return
      if (first == "" && cur !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        first = cur; b = cur; sub(/^.*\//, "", b)
        tool = (b == "git" || b == "gh") ? b : ""
      } else if (tool == "git" && cur == "commit") {
        tool = "commit"
      }
      prev = cur; cur = ""
    }
    function msgflag(w) {
      if (tool == "commit") return w == "-m" || w == "--message" || w == "-F" || w == "--file"
      if (tool == "gh") return w == "--body" || w == "-b" || w == "--title" || w == "-t" || w == "--body-file" || w == "-F"
      return 0
    }
    function pathflag(w) {
      return (tool == "commit" && (w == "-F" || w == "--file")) || (tool == "gh" && (w == "--body-file" || w == "-F"))
    }
    function attached(w) {
      if (tool == "commit") return w == "-m" || w ~ /^--(message|file)=$/
      if (tool == "gh") return w ~ /^--(body|title|body-file)=$/
      return 0
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf); out = ""; q = ""; cur = ""; prev = ""; first = ""; tool = ""
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (q != "") {
          out = out c
          if (q == "\"" && c == "\\") { i++; out = out substr(buf, i, 1); continue }
          if (c == q) q = ""
          continue
        }
        if (c == "\\") { i++; out = out c substr(buf, i, 1); cur = cur "x"; continue }
        if (c == "\047" || c == "\"") {
          if ((cur == "" && msgflag(prev)) || attached(cur)) {
            j = i + 1
            if (c == "\047") { while (j <= n && substr(buf, j, 1) != "\047") j++ }
            else { while (j <= n && substr(buf, j, 1) != "\"") { if (substr(buf, j, 1) == "\\") j++; j++ } }
            body = substr(buf, i + 1, j - i - 1)
            if (c == "\047" || (index(body, "$(") == 0 && index(body, "`") == 0)) {
              out = out "\047\047"; i = j; cur = cur "x"; continue
            }
          }
          q = c; out = out c; cur = cur "x"; continue
        }
        if (c == " " || c == "\t") { endword(); out = out c; continue }
        if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "\n") {
          endword(); first = ""; prev = ""; tool = ""; out = out c; continue
        }
        # An unquoted path value of -F/--body-file (`-F msg.txt`): drop the
        # word, so no file-scanning check reads the message file.
        if (cur == "" && pathflag(prev) && c != "-") {
          while (i <= n && substr(buf, i, 1) !~ /[ \t;&|()\n]/) i++
          i--; prev = ""; continue
        }
        cur = cur c; out = out c
      }
      printf "%s", out
    }
  ' <<<"${1-}"
}

# Both passes; a failure in either yields empty output, which the caller turns
# into "judge the raw command".
mtk_strip_inert_text() {
  local h
  h="$(mtk_strip_inert_heredocs "${1-}")" || return 1
  mtk_strip_message_values "$h"
}

# Judge the executable text (one segment per line) for destructive commands.
# Prints the reason and returns 0 on the first hit; returns 1 when clean.
# Tokens are matched with their quotes removed, so a quoted "/" is still `/`.
# Recursive force deletes are rm_broad's call (MTK_RM_AWK, shared with the
# backstop in hooks/lib/gate-backstop.sh, sourced before this runs); under xargs
# the paths arrive on stdin, so any recursive force delete blocks.
# Linear in the text: per piece (a line cut at $( and backticks) at most 16 git
# and 16 find words are judged, each scanning to the piece end.
mtk_destructive_reason() {
  awk -v RMR="$MTK_RM_DENY_REASON" -v RMG="$MTK_RM_GIT_REASON" -v RMX="$MTK_RM_XARGS_REASON" "${MTK_RM_AWK}"'
    function base(t) { sub(/^.*\//, "", t); return t }
    # Shared branches no force variant may rewrite, lease or not. A glob
    # refspec (refs/heads/*) can match them, so it counts as shared.
    function protected_ref(r) {
      sub(/^\+/, "", r); sub(/^refs\/heads\//, "", r)
      return r == "main" || r == "master" || r == "develop" || r ~ /^release\// || index(r, "*") > 0
    }
    function expand(d) {
      if (d == "~") return ENVIRON["HOME"]
      if (substr(d, 1, 2) == "~/") return ENVIRON["HOME"] substr(d, 2)
      sub(/^[$]HOME/, ENVIRON["HOME"], d)
      return d
    }
    # Directory the push runs in: the latest cd/pushd target (popd restores the
    # previous one), then -C <dir> relative to it.
    function push_dir(cdir, gdir) {
      cdir = expand(cdir); gdir = expand(gdir)
      if (gdir == "") return cdir
      if (substr(gdir, 1, 1) == "/" || cdir == "") return gdir
      return cdir "/" gdir
    }
    # Branch HEAD points at for that repo (honouring --git-dir / GIT_DIR and
    # --work-tree); "" when it cannot be determined (not a repo, detached HEAD,
    # git error) — the caller then denies.
    function current_branch(dir, gd, wt,   cmd, b) {
      cmd = "git" (dir != "" ? " -C \"" dir "\"" : "") (gd != "" ? " --git-dir=\"" expand(gd) "\"" : "") \
            (wt != "" ? " --work-tree=\"" expand(wt) "\"" : "") " symbolic-ref --short -q HEAD 2>/dev/null"
      # One git per distinct repo, however many pushes name it.
      if (cmd in BRANCH) return BRANCH[cmd]
      b = ""
      if ((cmd | getline b) <= 0) b = ""
      close(cmd)
      BRANCH[cmd] = b
      return b
    }
    # ${NAME…} -> $NAME, so ${HOME} is $HOME and ${x} -rf is $x -rf. One pass
    # over the pieces between "${", each up to the first "}" (which may sit in
    # a later piece, as in ${a:-${b}}): a match() loop restarting at the line
    # start was quadratic in the number of ${.
    function dollar_brace(line,   np, P, out, q, s, v, c) {
      if (index(line, "${") == 0) return line
      np = split(line, P, /[$][{]/); out = P[1]; q = 2
      while (q <= np) {
        s = P[q]; q++
        if (s !~ /^[A-Za-z_]/) { out = out "${" s; continue }
        while (index(s, "}") == 0 && q <= np) { s = s "${" P[q]; q++ }
        c = index(s, "}")
        if (c == 0) { out = out "${" s; continue }
        v = s; sub(/[^A-Za-z0-9_].*$/, "", v)
        out = out "$" v substr(s, c + 1)
      }
      return out
    }
    # Does option `a` (value after "=" ignored) name long option `full`, either
    # spelled out or as an unambiguous abbreviation of at least `min` chars?
    # git accepts any unique prefix, so `--force-w` is --force-with-lease.
    function opt(a, full, min,   name) {
      name = a; sub(/=.*/, "", name)
      return length(name) >= min && substr(full, 1, length(name)) == name
    }
    {
      # Recursive force deletes: every operand, judged on the raw text.
      v = rm_broad($0)
      if (v == 3) { print RMX; found = 1; exit }
      if (v == 2) { print RMG; found = 1; exit }
      if (v) { print RMR; found = 1; exit }
      line = $0
      # Unquote, and split at parens/braces too, so a command inside system("...")
      # or a ( subshell ) is a word of its own. Backslashes go first: `\git`
      # and `g\it` are git to the shell, and `"ef"` is ef.
      gsub(/\\/, "", line)
      gsub(/["\047]/, "", line)
      # ${NAME…} -> $NAME before braces split words: ${GIT_DIR} is $GIT_DIR.
      line = dollar_brace(line)
      npc = split(line, PC, /[$][(]|`/)
      for (pc = 1; pc <= npc; pc++) {
      n = split(PC[pc], t, /[ \t(){}]+/); ngit = 0; nfind = 0
      for (k = 1; k <= n; k++) {
        if (t[k] == "cd" && t[k + 1] != "") lastcd = t[k + 1]
        if (t[k] == "pushd" && t[k + 1] != "") { dstack[++dtop] = lastcd; lastcd = t[k + 1] }
        if (t[k] == "popd") { lastcd = (dtop > 0) ? dstack[dtop--] : "" }
        if (t[k] ~ /^GIT_DIR=/) { envgitdir = t[k]; sub(/^GIT_DIR=/, "", envgitdir) }
        if (t[k] ~ /^GIT_WORK_TREE=/) { envworktree = t[k]; sub(/^GIT_WORK_TREE=/, "", envworktree) }
        if (base(t[k]) == "dotnet" && t[k + 1] == "ef" && t[k + 2] == "database" && t[k + 3] == "drop") {
          print "dotnet ef database drop deletes the database. Use a migration instead."; found = 1; exit
        }
        if (base(t[k]) == "find" && ++nfind <= 16) {
          for (m = k + 1; m <= n; m++) {
            if (t[m] == "-delete") {
              print "find -delete removes every match with no review. List the matches first and delete specific paths."; found = 1; exit
            }
            if ((t[m] == "-exec" || t[m] == "-execdir" || t[m] == "-ok" || t[m] == "-okdir") && base(t[m + 1]) == "rm") {
              print "find -exec rm removes every match with no review. List the matches first and delete specific paths."; found = 1; exit
            }
          }
        }
        if (base(t[k]) == "git" && ++ngit <= 16) {
          j = k + 1; gitdir = ""; gd = envgitdir; wt = envworktree
          while (j <= n && (t[j] == "-C" || t[j] == "-c" || t[j] ~ /^--/ || t[j] == "-p" || t[j] == "")) {
            if (t[j] == "-C") gitdir = t[j + 1]
            if (t[j] == "--git-dir") gd = t[j + 1]
            if (t[j] ~ /^--git-dir=/) { gd = t[j]; sub(/^--git-dir=/, "", gd) }
            if (t[j] == "--work-tree") wt = t[j + 1]
            if (t[j] ~ /^--work-tree=/) { wt = t[j]; sub(/^--work-tree=/, "", wt) }
            if (t[j] == "-C" || t[j] == "-c" || t[j] == "--git-dir" || t[j] == "--work-tree") j++
            j++
          }
          sc = t[j]
          if (sc == "push") {
            # hard = --force / -f / +refspec (blocked everywhere); lease =
            # --force-with-lease[=ref[:sha]] / --force-if-includes (allowed only
            # to branches that are not shared). The target is each refspec
            # destination; with no refspec it is the current branch. --repo
            # names the remote, so every positional is then a refspec.
            # del = --delete / -d (every refspec names a remote ref to delete);
            # delprot = a `:dst` refspec deleting a shared branch.
            hard = 0; lease = 0; prot = 0; npos = 0; allrefs = 0; unknown = 0; repo = 0; del = 0; delprot = 0
            dir = push_dir(lastcd, gitdir)
            for (m = j + 1; m <= n; m++) {
              a = t[m]
              if (a == "") continue
              if (opt(a, "--repo", 5)) { repo = 1; if (index(a, "=") == 0) m++; continue }
              if (a == "-o" || opt(a, "--push-option", 4) || opt(a, "--receive-pack", 5) || opt(a, "--exec", 4)) {
                if (a == "-o" || index(a, "=") == 0) m++
                continue
              }
              if (opt(a, "--force-with-lease", 9) || opt(a, "--force-if-includes", 9)) {
                lease = 1
                if (index(a, "=")) {
                  r = a; sub(/^[^=]*=/, "", r); sub(/:.*/, "", r)
                  if (protected_ref(r)) prot = 1
                }
                continue
              }
              if (opt(a, "--mirror", 3)) {
                print "git push --mirror force-overwrites and deletes every ref on the remote. Push the branches you mean, by name."; found = 1; exit
              }
              if (opt(a, "--all", 4) || opt(a, "--branches", 4)) { allrefs = 1; continue }
              if (opt(a, "--force", 4) || a ~ /^-[A-Za-z]*f[A-Za-z]*$/) { hard = 1; continue }
              if (opt(a, "--delete", 4) || a ~ /^-[A-Za-z]*d[A-Za-z]*$/) { del = 1; continue }
              if (a ~ /^-/) continue
              npos++
              if (npos == 1 && !repo) continue
              if (a ~ /^\+./) hard = 1
              r = a
              if (index(r, ":")) sub(/^[^:]*:/, "", r)
              if (r == "HEAD") { r = current_branch(dir, gd, wt); if (r == "") unknown = 1 }
              if (protected_ref(r)) { prot = 1; if (a ~ /^\+?:/) delprot = 1 }
            }
            if (delprot || (del && prot)) {
              print "Deleting a shared branch (main, master, develop, release/*, or a refspec glob) from the remote is not allowed."; found = 1; exit
            }
            refs = npos - (repo ? 0 : 1)
            if ((hard || lease) && refs < 1 && !allrefs) {
              r = current_branch(dir, gd, wt)
              if (r == "") unknown = 1
              if (protected_ref(r)) prot = 1
            }
            if ((hard || lease) && allrefs) prot = 1
            if (hard) {
              print "Force push is not allowed. Use --force-with-lease on your own branch, which refuses to overwrite work you have not seen."; found = 1; exit
            }
            if (lease && unknown) {
              print "Force push with --force-with-lease, but the gate cannot determine the target branch. Name the branch explicitly: git push --force-with-lease origin <branch>."; found = 1; exit
            }
            if (lease && prot) {
              print "Force push to a shared branch (main, master, develop, release/*, or a refspec glob) is not allowed, --force-with-lease included. Push a new branch and open a pull request."; found = 1; exit
            }
          } else if (sc == "reset") {
            for (m = j + 1; m <= n; m++) if (opt(t[m], "--hard", 4)) {
              print "git reset --hard discards uncommitted work. Use git stash or git reset --soft/--mixed."; found = 1; exit
            }
          } else if (sc == "clean") {
            force = 0; dry = 0
            for (m = j + 1; m <= n; m++) {
              if (t[m] == "--dry-run" || t[m] ~ /^-[A-Za-z]*n/) dry = 1
              if (t[m] == "--force" || t[m] ~ /^-[A-Za-z]*f/) force = 1
            }
            if (force && !dry) {
              print "git clean -f deletes untracked files for good. Run git clean -n first and remove specific paths."; found = 1; exit
            }
          }
        }
      }
      }
    }
    # exit in a main rule still runs END, so END decides the status.
    END { exit (found ? 0 : 1) }
  ' <<<"${1-}"
}

# Does the command run a download as code? 0 yes, 1 no (anything else: awk
# failed, and the caller denies). Each $( … ), backtick span and <( … ) is
# reduced, innermost first, to a marker: @DL@ (@DLP@ for <( … )) when its text
# names curl or wget (any path, any position: `$(true; /usr/bin/curl …)`) or
# holds a marked span, @S@ otherwise. Then, per segment, after peeling
# assignments, control words and sudo/env/command/exec/nohup/nice/time:
#   - eval, source and `.` deny on any marked word or a tainted variable;
#   - bash/sh/zsh/dash/ksh/python*/perl/ruby/node deny on a <( download ), on
#     stdin (< or <<<) from a download, on a download as the code of
#     -c/-e/-E/-p/--eval, and on a download as the script path;
#   - a variable assigned from a download (x=$(curl …), export/local/declare)
#     is tainted for the rest of the command.
# A download whose output is only read (`x=$(curl -s u)`, `curl -o f u`,
# `bash ./install.sh "$(curl -s u)"`) is not denied.
mtk_download_exec() {
  awk '
    function dl(s) { return index(s, "@DL") || s ~ /(^|[^A-Za-z0-9_.-])(curl|wget)([^A-Za-z0-9_.-]|$)/ }
    function close_span(   m) {
      buf[top] = buf[top] substr(T, run, i - run); run = i + 1
      m = dl(buf[top]) ? (kind[top] == "p" ? "@DLP@" : "@DL@") : "@S@"
      top--; buf[top] = buf[top] m
    }
    function bad(a,   tmp, v) {
      if (index(a, "@DL")) return 1
      tmp = a
      while (match(tmp, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) {
        v = substr(tmp, RSTART, RLENGTH); sub(/^[$][{]?/, "", v)
        if (v in TAINT) return 1
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      return 0
    }
    function taint(a,   name, val) {
      name = a; sub(/=.*/, "", name); val = a; sub(/^[^=]*=/, "", val)
      if (bad(val)) TAINT[name] = 1
    }
    function judge(t,   segs, ns, k, s, w, nw, j, m, cw, a, first) {
      ns = split(t, segs, /[;&|\n]/)
      for (k = 1; k <= ns; k++) {
        s = segs[k]; gsub(/["\047\\]/, "", s)
        nw = split(s, w, /[ \t]+/); j = 1
        while (j <= nw) {
          if (w[j] == "") { j++; continue }
          if (w[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { taint(w[j]); j++; continue }
          if (w[j] ~ /^(!|time|command|builtin|exec|nohup|then|do|else|elif|if|while|until|[{(])$/) { j++; continue }
          if (w[j] == "nice") { j++; if (w[j] == "-n") j += 2; else if (w[j] ~ /^-/) j++; continue }
          if (w[j] == "sudo") {
            j++
            while (j <= nw && w[j] ~ /^-/) { if (w[j] ~ /^-[ugCDhpRrT]$/) j++; j++ }
            continue
          }
          if (w[j] == "env") { j++; while (j <= nw && (w[j] ~ /^-/ || w[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) j++; continue }
          if (w[j] ~ /^(export|local|declare|readonly|typeset)$/) {
            for (m = j + 1; m <= nw; m++) if (w[m] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) taint(w[m])
            j = nw + 1; continue
          }
          break
        }
        if (j > nw) continue
        cw = w[j]; sub(/^.*\//, "", cw)
        if (cw == "eval" || cw == "source" || cw == ".") {
          for (m = j + 1; m <= nw; m++) if (bad(w[m])) return 1
        } else if (cw ~ /^(bash|sh|zsh|dash|ksh|python[0-9.]*|perl|ruby|node)$/) {
          first = 1
          for (m = j + 1; m <= nw; m++) {
            a = w[m]
            if (index(a, "@DLP@")) return 1
            if (a ~ /^[0-9]*<<?<?$/) { if (bad(w[m + 1])) return 1; m++; continue }
            if (a ~ /^[0-9]*</ && bad(a)) return 1
            if (a ~ /^-(c|e|E|p|-eval)$/ || a ~ /^-[A-Za-z]+c$/) { if (bad(w[m + 1])) return 1; m++; continue }
            if (a ~ /^-/) continue
            if (first) { first = 0; if (bad(a)) return 1 }
          }
        }
      }
      return 0
    }
    { T = T (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(T); top = 0; buf[0] = ""; kind[0] = "o"; dep[0] = 0; run = 1
      for (i = 1; i <= n; i++) {
        c = substr(T, i, 1)
        if ((c == "$" || c == "<") && substr(T, i + 1, 1) == "(") {
          buf[top] = buf[top] substr(T, run, i - run)
          top++; buf[top] = ""; kind[top] = (c == "<") ? "p" : "s"; dep[top] = 0; i++; run = i + 1; continue
        }
        if (c == "`") {
          if (kind[top] == "b") { close_span(); continue }
          buf[top] = buf[top] substr(T, run, i - run); run = i + 1
          top++; buf[top] = ""; kind[top] = "b"; dep[top] = 0; continue
        }
        if (top == 0 || kind[top] == "b") continue
        if (c == "(") dep[top]++
        else if (c == ")") { if (dep[top] > 0) dep[top]--; else close_span() }
      }
      i = n + 1
      while (top > 0) close_span()
      buf[0] = buf[0] substr(T, run)
      exit (judge(buf[0]) ? 0 : 1)
    }
  ' <<<"${1-}"
}

# S3.17: every match below feeds grep -q through process substitution, never a
# pipe. grep -q exits on its first match, the producer takes SIGPIPE (141), and
# pipefail turns that *success* into a non-zero pipeline — so `if <pipeline>` reads
# FALSE and the guard FAILS OPEN on exactly the destructive commands it exists to
# block. Process-substitution exit status is ignored, so the match stands on its own.
# The destructive-SQL pattern lives in one place so the command text and any file the
# command executes are judged by identical rules.
#
# mtk_sql_hit MODE TEXT: 0 when TEXT holds destructive SQL, 1 when clean. MODE
# d: per line, DROP TABLE|DATABASE|SCHEMA, TRUNCATE TABLE, DELETE FROM x with
# nothing after it (no WHERE). MODE t adds, on the whole text with lines
# joined, TRUNCATE without TABLE at the start of a statement (`TRUNCATE users`,
# `TRUNCATE ONLY t`, the target on the next line) and DROP/TRUNCATE TABLE split
# across lines: only for text the gate knows is SQL (a client's -c value,
# heredoc, here-string, echo/printf input, or a file it reads), because
# elsewhere the word is prose or the coreutils truncate command.
# Comments: `/* … */` (any content, any lines) and `--` to end of line are
# whitespace to SQL, so `DROP/**/TABLE` is DROP TABLE. The text is judged both
# as written and with comments removed, and either hit denies: removal alone
# would let `SELECT '/*'; DROP …; SELECT '*/'` hide the statement.
# An awk failure counts as a hit (fail closed).
mtk_sql_hit() {
  case "${2-}" in
    *[Dd][Rr][Oo][Pp]*|*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*|*[Dd][Ee][Ll][Ee][Tt][Ee]*) ;;
    *) return 1 ;;
  esac
  local rc=0
  awk -v mode="$1" '
    function strip(s,   out, a, b, j) {
      out = ""
      while (1) {
        a = index(s, "/*"); b = index(s, "--")
        if (a == 0 && b == 0) break
        if (a && (b == 0 || a < b)) {
          out = out substr(s, 1, a - 1) " "; s = substr(s, a + 2); j = index(s, "*/")
          if (j == 0) { s = ""; break }
          s = substr(s, j + 2)
        } else {
          out = out substr(s, 1, b - 1) " "; s = substr(s, b + 2); j = index(s, "\n")
          if (j == 0) { s = ""; break }
          s = substr(s, j)
        }
      }
      return out s
    }
    function lines_hit(s,   n, a, k) {
      n = split(s, a, "\n")
      for (k = 1; k <= n; k++)
        if (a[k] ~ /drop[ \t\r]+(table|database|schema)/ || a[k] ~ /truncate[ \t\r]+table/ \
            || a[k] ~ /delete[ \t\r]+from[ \t\r]+[^ \t\r]+[ \t\r]*;?[ \t\r]*$/) return 1
      return 0
    }
    function joined_hit(s) {
      return s ~ /(^|[;\n])[ \t\r\n]*truncate[ \t\r\n]+[a-z_"`[\\]/ \
          || s ~ /(drop[ \t\r\n]+(table|database|schema)|truncate[ \t\r\n]+table)/
    }
    { T = T (NR > 1 ? "\n" : "") $0 }
    END {
      t = tolower(T); s = ""
      if (index(t, "/*") || index(t, "--")) s = strip(t)
      if (lines_hit(t) || (s != "" && lines_hit(s))) exit 0
      if (mode == "t" && (joined_hit(t) || (s != "" && joined_hit(s)))) exit 0
      exit 1
    }
  ' <<<"${2-}" || rc=$?
  [ "$rc" -ne 1 ]
}
mtk_has_destructive_sql() { mtk_sql_hit d "${1-}"; }
mtk_has_sql_truncate() { mtk_sql_hit t "${1-}"; }

# SQL a database client (psql mysql mariadb sqlcmd sqlite3 usql, by any path,
# inside docker exec or $(…) too) receives, out of the whole command:
#   mtk_sql_client_inputs text: the values of -c/-e/-Q/-q/--command/--execute
#     (quotes and backslash escapes resolved, so -c "TRUNCATE \"t\"" and
#     -c TRUNCATE\ t are read as SQL), here-strings, heredoc bodies, and the
#     arguments of echo/printf piped into the client; items are separated by
#     a `;` line so one item never completes another.
#   mtk_sql_client_inputs files: the files it reads: -f/--file (-i for
#     sqlcmd), `< file`, and `cat file … |` into the client.
# A heredoc of a pipeline with no client (`cat <<EOF > notes.md`) is skipped.
mtk_sql_client_inputs() {
  awk -v mode="$1" "${MTK_RM_AWK}"'
    function client(w) { sub(/^.*[\/(=`]/, "", w); return w ~ /^(psql|mysql|mariadb|sqlcmd|sqlite3|usql)$/ }
    function emit(s) { if (mode == "text") OUT = OUT s "\n;\n" }
    function file(f) { if (mode == "files" && f != "" && f !~ /^-/) print f }
    # Command word of tokens a..b (basename), its index in CWPOS.
    function cmdword(a, b,   j, w) {
      for (j = a; j <= b; j++) {
        if (RK[j] == "r") { j++; continue }
        if (RK[j] != "w") continue
        w = unquote(RW[j])
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w ~ /^(sudo|env|time|command|exec|nohup|!)$/) continue
        CWPOS = j; sub(/^.*\//, "", w); return w
      }
      CWPOS = b + 1; return ""
    }
    # Every heredoc opener in tokens a..b, in order; sql: its body is SQL.
    function heredocs(a, b, sql,   j) {
      for (j = a; j < b; j++)
        if (RK[j] == "r" && RW[j] ~ /<<-?$/ && RW[j] !~ /<<<$/ && RK[j + 1] == "w") {
          NH++; HD[NH] = unquote(RW[j + 1]); HT[NH] = (RW[j] ~ /-$/); HS[NH] = sql
        }
    }
    # One stage (tokens a..b) of a pipeline that holds a client.
    function stage(a, b,   j, w, u, v, cw, isc) {
      cw = cmdword(a, b); isc = 0
      for (j = a; j <= b; j++) if (RK[j] == "w" && client(RW[j])) isc = 1
      heredocs(a, b, 1)
      for (j = a; j <= b; j++) {
        w = RW[j]
        if (RK[j] == "r") {
          if (j < b && RK[j + 1] == "w") {
            if (w ~ /<<<$/) emit(unquote(RW[j + 1]))
            else if (w ~ /^[0-9]*<$/) file(unquote(RW[j + 1]))
            j++
          }
          continue
        }
        if (RK[j] != "w") continue
        u = unquote(w)
        if (isc) {
          if (u ~ /^--(command|execute|file)=/) {
            v = u; sub(/^[^=]*=/, "", v)
            if (u ~ /^--file=/) file(v); else emit(v)
          } else if (u ~ /^-(c|e|Q|q)$/ || u == "--command" || u == "--execute") {
            if (j < b && RK[j + 1] == "w" && RW[j + 1] !~ /^-/) { emit(unquote(RW[j + 1])); j++ }
          } else if (u == "-f" || u == "--file" || (u == "-i" && cw == "sqlcmd")) {
            if (j < b && RK[j + 1] == "w") { file(unquote(RW[j + 1])); j++ }
          }
        } else if (cw == "cat" && j > CWPOS) file(u)
      }
      if (!isc && (cw == "echo" || cw == "printf")) {
        v = ""
        for (j = CWPOS + 1; j <= b; j++) {
          if (RK[j] == "r") { j++; continue }
          if (RK[j] == "w") v = v " " unquote(RW[j])
        }
        gsub(/\\n/, "\n", v); emit(v)
      }
    }
    # A pipeline (tokens a..b, stages split at a single |).
    function pipeline(a, b,   j, sq, s0) {
      sq = 0
      for (j = a; j <= b; j++) if (RK[j] == "w" && client(RW[j])) sq = 1
      if (!sq) { heredocs(a, b, 0); return }
      s0 = a
      for (j = a; j <= b + 1; j++) {
        if (j <= b && !(RK[j] == "b" && RW[j] == "|")) continue
        if (j > s0) stage(s0, j - 1)
        s0 = j + 1
      }
    }
    # Quote open at the end of s, scanning from quote state q ("" for none).
    function qstate(s, q,   n, ch, k, c) {
      n = split(s, ch, "")
      for (k = 1; k <= n; k++) {
        c = ch[k]
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { k++; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "\047" || c == "\"") q = c
      }
      return q
    }
    { L[++NL] = $0 }
    END {
      i = 1
      while (i <= NL) {
        line = L[i]; i++
        # A backslash-newline continues the line; an open quote spans lines.
        q = qstate(line, "")
        while (i <= NL && (q != "" || line ~ /\\$/)) {
          if (q == "") { line = substr(line, 1, length(line) - 1) " " L[i] }
          else line = line "\n" L[i]
          q = qstate(L[i], q); i++
        }
        rm_words(line)
        # Pipelines end at any boundary but a single |.
        NH = 0; ps = 1
        for (j = 1; j <= RN + 1; j++) {
          if (j <= RN && RK[j] != "b") continue
          if (j <= RN && RW[j] == "|" && !(j < RN && RW[j + 1] == "|") && !(j > 1 && RW[j - 1] == "|")) continue
          if (j > ps) pipeline(ps, j - 1)
          ps = j + 1
        }
        # Heredoc bodies follow the line, in order.
        for (h = 1; h <= NH; h++) {
          body = ""
          while (i <= NL) {
            l = L[i]; i++; cmp = l
            if (HT[h]) sub(/^\t+/, "", cmp)
            if (cmp == HD[h]) break
            body = body l "\n"
          }
          if (HS[h]) emit(body)
        }
      }
      if (mode == "text") printf "%s", OUT
    }
  ' <<<"${2-}"
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
mtk_db_input_files() {
  awk '
    function word0(seg,   n, t, k) {
      n = split(seg, t, /[ \t]+/)
      for (k = 1; k <= n; k++) {
        if (t[k] == "" || t[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t[k] == "sudo" || t[k] == "env" || t[k] == "time" || t[k] == "!") continue
        w = t[k]; sub(/^.*\//, "", w); return w
      }
      return ""
    }
    { buf = buf $0 "\n" }
    END {
      gsub(/\\/, "", buf)
      m = split(buf, segs, /[;&|\n()]+/)
      for (s = 1; s <= m; s++) {
        seg = segs[s]; w = word0(seg)
        if (w ~ /^(git|gh|rm|cp|mv|ln|tail|grep|egrep|fgrep|rg|touch|chmod|chown|ls|make|tar|docker-compose)$/) continue
        rest = " " seg
        while (match(rest, /[ \t](-f|--file)([ \t]+|=)["\047]?[A-Za-z0-9_.:@~\/+-]+/)) {
          f = substr(rest, RSTART, RLENGTH); sub(/^[ \t](-f|--file)([ \t]+|=)["\047]?/, "", f); print f
          rest = substr(rest, RSTART + RLENGTH)
        }
        rest = seg
        while (match(rest, /(^|[^<0-9])<[ \t]*["\047]?[A-Za-z0-9_.:@~\/+-]+/)) {
          f = substr(rest, RSTART, RLENGTH); sub(/^[^<]*<[ \t]*["\047]?/, "", f); print f
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
    }
  ' <<<"${1-}"
}

mtk_referenced_files() {
  local _cmd="${1-}"
  {
    # An interpreter runs it: bash x.sh, sh ./x.sh, source x.sh, . x.sh
    printf '%s' "$_cmd" | grep -oiE '(^|[;&|(]|[[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[A-Za-z0-9_.:@~/+-]+' || true
    # It is executed directly: ./x.sh, /opt/x.bash. Anchored to command position — after a
    # separator, not after a space — because `git add /tmp/x.sh` passes an absolute path as an
    # argument and that is not execution.
    printf '%s' "$_cmd" | grep -oE '(^|[;&|(])[[:space:]]*\.?/[A-Za-z0-9_.:@~/+-]+\.(sh|bash|zsh)' || true
    # A database client reads it: psql -f x.sql, usql --file=x.sql, mysql db < x.sql,
    # `$PSQL -f`, `docker exec db psql -f`. Any command counts EXCEPT a short
    # deny-list of commands that never run a file as SQL (git, gh, rm, cp, …):
    # an allow-list of clients missed every client it did not name.
    mtk_db_input_files "$_cmd"
  } 2>/dev/null \
    | grep -oE '[A-Za-z0-9_.:@~/+-]+$' \
    | sort -u
}

# Judge the command with only git/gh message text removed (mtk_strip_inert_text).
# Never fail open: if stripping fails or yields nothing, judge the raw command.
NORM="$(mtk_strip_inert_text "$COMMAND" 2>/dev/null || true)"
# A case match, not `${NORM//[[:space:]]/}`: on macOS bash 3.2 that substitution
# is super-linear and took minutes on a 10k-char heredoc command, past the 5s
# hook timeout (tests/hooks/test-security-gate-long-command.sh).
case "$NORM" in *[![:space:]]*) ;; *) NORM="$COMMAND" ;; esac

# Segment and substitution caps (see the size cap above). Segments are the
# pieces between ; | & and newlines, the unit the judging loops walk; a piece
# holding `$(` or a backtick forks a splitter. Counted only when the text is
# long enough to exceed either cap, so an ordinary command pays nothing.
# The body of a heredoc with a quoted delimiter (<<'EOF', <<"EOF", <<\EOF) is
# not expanded by the shell, so its $( and backticks are not substitutions and
# are not counted (a markdown file full of `code` spans is not 1500 commands).
# The body is still judged line by line, like any other text.
# Counted only when the text is long enough to exceed a cap (each substitution
# segment takes at least 2 bytes, each shell -c 5), so an ordinary command pays
# nothing.
_mtk_cnt_min=128
[ $(( MTK_GATE_MAX_SUBST * 2 )) -ge "$_mtk_cnt_min" ] || _mtk_cnt_min=$(( MTK_GATE_MAX_SUBST * 2 ))
[ $(( MTK_GATE_MAX_SHELL_C * 5 )) -ge "$_mtk_cnt_min" ] || _mtk_cnt_min=$(( MTK_GATE_MAX_SHELL_C * 5 ))
if [ "${#NORM}" -gt "$_mtk_cnt_min" ] || [ "${#NORM}" -ge "$MTK_GATE_MAX_SEGMENTS" ]; then
  MTK_COUNTS="$(awk '
    { n = split($0, p, /[;|&]/); if (n == 0) n = 1; seg += n
      sc += gsub(/(bash|sh|zsh|dash|ksh)[ \t]+-(c|lc|ec)/, "&")
      if (hd != "") {
        t = $0; if (ht) sub(/^\t+/, "", t); if (t == hd) hd = ""
        all += gsub(/[$][(]/, "&"); bt += gsub(/`/, "&"); next
      }
      for (i = 1; i <= n; i++) if (index(p[i], "$(") || index(p[i], "`")) subst++
      all += gsub(/[$][(]/, "&"); bt += gsub(/`/, "&")
      if (match($0, /<<-?[ \t]*(\047[^\047]*\047|"[^"]*"|\\[^ \t;&|<>()]+)/) && (RSTART == 1 || substr($0, RSTART - 1, 1) != "<")) {
        d = substr($0, RSTART, RLENGTH); ht = (d ~ /^<<-/); sub(/^<<-?[ \t]*/, "", d); gsub(/[\\"\047]/, "", d); hd = d
      } }
    END { print seg + 0, subst + 0, all + int((bt + 1) / 2), sc + 0 }
  ' <<<"$NORM" 2>/dev/null || true)"
  case "$MTK_COUNTS" in
    [0-9]*' '[0-9]*' '[0-9]*' '[0-9]*) ;;
    *) gate_deny "BLOCKED: the security gate could not measure this command. Re-run it in a simpler form." ;;
  esac
  read -r _mtk_c_seg _mtk_c_sub _mtk_c_all _mtk_c_sc <<<"$MTK_COUNTS"
  [ "$_mtk_c_seg" -le "$MTK_GATE_MAX_SEGMENTS" ] || gate_too_long segments "$_mtk_c_seg" "$MTK_GATE_MAX_SEGMENTS"
  [ "$_mtk_c_sc" -le "$MTK_GATE_MAX_SHELL_C" ] || gate_too_long "shell -c commands" "$_mtk_c_sc" "$MTK_GATE_MAX_SHELL_C"
  [ "$_mtk_c_sub" -le "$MTK_GATE_MAX_SUBST" ] || gate_too_long "segments with a command substitution" "$_mtk_c_sub" "$MTK_GATE_MAX_SUBST"
  # Every substitution body is judged on its own, so one segment holding
  # thousands of them (`echo $(a)$(a)…`) costs seconds however few segments
  # it spans (~0.23 ms each, measured 2026-11-12). This total includes the
  # spans in quoted heredoc bodies, which are judged too: 4096 is ~1 s of CPU,
  # and a markdown file with 1500 code spans uses a third of it.
  [ "$_mtk_c_all" -le $(( MTK_GATE_MAX_SUBST * 4 )) ] || gate_too_long "command substitutions" "$_mtk_c_all" "$(( MTK_GATE_MAX_SUBST * 4 ))"
fi

# Layer 1 — the de0c626 regex backstop (hooks/lib/gate-backstop.sh), run over the
# same text. Any hit denies; the token checks below can only add denials.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gate-backstop.sh"
if BACKSTOP_REASON="$(mtk_backstop_reason "$NORM")"; then
  gate_deny "BLOCKED: ${BACKSTOP_REASON}"
fi

# Layer 2 — token checks.
# Decoded or downloaded text piped into an interpreter runs code nobody has read.
if grep -qE 'base64[[:space:]]+([^|]*[[:space:]])?(-d|-D|--decode)([[:space:]][^|]*)?\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(bash|sh|zsh|dash|ksh)([[:space:]]|$)' <<<"$NORM"; then
  gate_deny "BLOCKED: Piping decoded base64 into a shell runs hidden code. Decode to a file, read it, then run it."
fi
if grep -qE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(python[0-9.]*|node|perl|ruby)([[:space:]]|$)' <<<"$NORM"; then
  gate_deny "BLOCKED: Piping a download into an interpreter (curl … | python). Download the script, read it, then run it."
fi

# A download piped into a shell runs code nobody has read.
if grep -qE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(bash|sh|zsh|dash|ksh)([[:space:]]|$)' <<<"$NORM" \
  || grep -qE '(bash|sh|zsh)[[:space:]]+(-c[[:space:]]+)?["'"'"']?(<\(|\$\()[[:space:]]*(curl|wget)' <<<"$NORM"; then
  gate_deny "BLOCKED: Piping a download into a shell (curl … | sh). Download the script, read it, then run it."
fi
# eval or source of a download runs it the same way: eval "$(curl …)",
# eval `wget …`, source <(curl …), . <(wget …). The case keeps the grep off
# the allow path of commands that download nothing.
case "$NORM" in
  *curl*|*wget*)
    if grep -qE '(^|[^A-Za-z0-9_.-])(eval|source|\.)[[:space:]]+["'"'"']?(<\(|\$\(|`)[[:space:]]*(curl|wget)([[:space:]]|$)' <<<"$NORM"; then
      gate_deny "BLOCKED: Evaluating or sourcing a download (eval \"\$(curl …)\", source <(curl …)) runs code nobody has read. Download the script, read it, then run it."
    fi
    # The same in any other spelling (mtk_download_exec): /usr/bin/curl,
    # $(true; curl …), sudo/env/command prefixes, eval -- …, source /dev/stdin
    # < <(curl …), bash <(curl …), python3 -c "$(curl …)", x=$(curl …); eval $x.
    # Status 1 is "clean"; anything else, an awk failure included, denies.
    _mtk_dl_rc=0
    mtk_download_exec "$NORM" || _mtk_dl_rc=$?
    if [ "$_mtk_dl_rc" -ne 1 ]; then
      gate_deny "BLOCKED: Running a download through eval, source or an interpreter (eval \"\$(curl …)\", bash <(curl …), python3 -c \"\$(curl …)\") runs code nobody has read. Download the script, read it, then run it."
    fi ;;
esac

# awk that shells out runs a command the read-only exemption never sees:
# system("…"), "cmd" | getline, print … | "cmd" (and gawk's |&). Checked on the
# whole command, because the segment split at `|` cuts these programs in half.
if grep -qE '(^|[^A-Za-z0-9_.-])[gmn]?awk([[:space:]]|$)' <<<"$NORM" \
  && grep -qE 'system[[:space:]]*\(|\|&|[^<|]\|[[:space:]]*getline|print[f]?[^;}|]*\|[[:space:]]*["A-Za-z_]' <<<"$NORM"; then
  gate_deny "BLOCKED: this awk program runs shell commands (system(), \"cmd\" | getline, or print | \"cmd\"). Run the command directly, where the gate can judge it."
fi

# Text piped into a shell executes, even when the producer is read-only
# (`echo '<delete>' | sh`): judge every segment, no read-only exemption.
mtk_gate_late && gate_deny "BLOCKED: ${MTK_GATE_LATE_REASON}"
if grep -qE '\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh)([[:space:]]|$)' <<<"$NORM"; then
  EXEC_TEXT="$(MTK_SPLIT_RAW=1 mtk_bs_judge_text mtk_bs_print_seg "$NORM")"
else
  EXEC_TEXT="$(mtk_executable_text "$NORM")"
fi
case "$EXEC_TEXT" in
  *"$MTK_GATE_LATE"*) gate_deny "BLOCKED: ${MTK_GATE_LATE_REASON}" ;;
  *"$MTK_GATE_SPLITERR"*) gate_deny "BLOCKED: ${MTK_GATE_SPLITERR_REASON}" ;;
esac

# `git -c key=value` values can execute: an alias starting with `!`, core.editor,
# core.pager, core.sshCommand, … Judge every dotted-key -c value as a command.
# One pipeline and one append: a per-value loop appending to EXEC_TEXT was
# quadratic (2.5 s for a 32 KB run of `-c a.b=c`).
case "$NORM" in
  *-c*)
    _mtk_cvals="$(grep -oE -- '-c[[:space:]]+[A-Za-z0-9_-]+[.][A-Za-z0-9_.-]+=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)' <<<"$NORM" \
      | sed -E 's/^-c[[:space:]]+[^=]*=//; s/^["'"'"']//; s/["'"'"']$//; s/^!//' || true)"
    [ -z "$_mtk_cvals" ] || EXEC_TEXT="${EXEC_TEXT}
${_mtk_cvals}" ;;
esac

# SQL a database client receives (mtk_sql_client_inputs): -c/-e/-Q values,
# here-strings, heredoc bodies, echo/printf piped in, and the files it reads.
# Judged as SQL, TRUNCATE without TABLE included. Each item sits on its own
# lines, so the DELETE-without-WHERE pattern (anchored at end of statement) sees
# the statement end rather than the flags that follow it. When the extractor
# fails, the whole command is judged as SQL instead (fail closed).
SQL_TEXT=""
SQL_FILES=""
case "$NORM" in
  *psql*|*mysql*|*mariadb*|*sqlcmd*|*sqlite3*|*usql*)
    SQL_TEXT="$(mtk_sql_client_inputs text "$NORM")" || SQL_TEXT="$NORM"
    SQL_FILES="$(mtk_sql_client_inputs files "$NORM")" \
      || gate_deny "BLOCKED: the security gate could not evaluate the SQL this command runs. Re-run it in a simpler form." ;;
esac

# Block: database destructive operations
if mtk_has_destructive_sql "$EXEC_TEXT" || { [ -n "$SQL_TEXT" ] && mtk_has_sql_truncate "$SQL_TEXT"; }; then
  gate_deny "BLOCKED: Destructive database operation detected. Use a migration instead."
fi

# A file under the repo's own tests/ tree carries destructive statements as fixtures, not
# as work to run: tests/hooks/test-security-gate.sh asserts that `DROP SCHEMA` is blocked,
# so it must contain the string to test for it. Scanning it makes the gate block its own
# regression suite — `bash tests/hooks/test-security-gate.sh` was denied outright. Scoped
# to tests/ inside this repo and resolved by device+inode (S1.17), so a destructive script
# anywhere else, or a tests/ path in some other checkout, is still read and still caught.
mtk_is_repo_test_file() {
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

# Block: the same, hidden one level down in a script or .sql file the command runs.
# Only existing regular files are read, and only their first 200 KB, so this stays cheap
# on every Bash call. This narrows the gap rather than closing it — a heredoc, a file
# generated at run time, or `curl … | bash` still carries SQL this never sees. Defence in
# depth, not a wall.
while IFS= read -r _mtk_ref; do
  [ -n "$_mtk_ref" ] || continue
  [ -f "$_mtk_ref" ] || continue
  mtk_is_repo_test_file "$_mtk_ref" && continue
  # Strip `#` comment lines from anything that is not a .sql file: a comment executes
  # nothing, and prose describing the blocked statements is exactly what this hook's
  # own source (and any doc-commented migration wrapper) contains. sed, not the bash
  # loop above, because this runs over up to 200 KB on every Bash call.
  case "$_mtk_ref" in
    *.sql|*.SQL) _mtk_body="$(head -c 200000 "$_mtk_ref" 2>/dev/null || true)" ;;
    *)           _mtk_body="$(head -c 200000 "$_mtk_ref" 2>/dev/null | sed 's/[[:space:]]*#.*$//' || true)" ;;
  esac
  if mtk_has_destructive_sql "$_mtk_body" \
    || { case "$_mtk_ref" in *.sql|*.SQL) mtk_has_sql_truncate "$_mtk_body" ;; *) false ;; esac; }; then
    gate_deny "BLOCKED: Destructive database operation found in ${_mtk_ref}. Use a migration instead."
  fi
done <<MTK_REFS
$(mtk_referenced_files "$NORM")
MTK_REFS

# A file a SQL client reads (-f, < file, cat file | client) is SQL whatever its
# extension, so it is judged as SQL text: TRUNCATE without TABLE included. Only
# readable regular files, first 200 KB; a file created by the command itself
# does not exist yet and cannot be judged here.
while IFS= read -r _mtk_ref; do
  [ -n "$_mtk_ref" ] || continue
  [ -f "$_mtk_ref" ] && [ -r "$_mtk_ref" ] || continue
  mtk_is_repo_test_file "$_mtk_ref" && continue
  _mtk_body="$(head -c 200000 "$_mtk_ref" 2>/dev/null || true)"
  if mtk_has_sql_truncate "$_mtk_body"; then
    gate_deny "BLOCKED: Destructive database operation found in ${_mtk_ref}. Use a migration instead."
  fi
done <<MTK_SQL_FILES
$SQL_FILES
MTK_SQL_FILES

# Block: force push, reset --hard, clean -f, rm -rf on broad paths, ef drop.
# Status 1 is "clean"; anything above it is an awk failure, and a gate that
# cannot evaluate a command must not wave it through.
mtk_gate_late && gate_deny "BLOCKED: ${MTK_GATE_LATE_REASON}"
REASON_RC=0
REASON="$(mtk_destructive_reason "$EXEC_TEXT" 2>/dev/null)" || REASON_RC=$?
case "$REASON_RC" in
  0) gate_deny "BLOCKED: ${REASON}" ;;
  1) ;;
  *) gate_deny "BLOCKED: the security gate could not evaluate this command (internal error ${REASON_RC}). Re-run it in a simpler form." ;;
esac

# ─── Interactive-prompt check (S4.12) ─────────────────────────────────────────
# Formerly hooks/interactive-guard.sh, merged here so the Bash payload is read and
# parsed once. It runs only after every destructive check passed, on the raw
# COMMAND (a pipe binds within one line, so heredoc prose is judged line by line
# below, never stripped). Kill-switch: MTK_INTERACTIVE_GUARD=0 — it disables this
# section only; the destructive checks above have no off-switch.
#
# The failure this prevents: `gh pr merge 272 --squash 2>&1 | tail -5` ran to the
# full Bash-tool timeout and returned "(No output)". The merge had already
# SUCCEEDED — gh then blocked on its post-merge "Delete the branch?" prompt, and
# `tail` buffers until EOF so the prompt never surfaced. Two independent blocks,
# because either alone causes it:
#   A. a prompt-capable command missing the flag that suppresses the prompt
#   B. a prompt-capable command piped into tail/head, which hides the prompt
# Scope is deliberately narrow: a hard deny that over-blocks gets switched off, so
# it fires only on commands that genuinely prompt, never on read-only ones.
[ "${MTK_INTERACTIVE_GUARD:-1}" = "0" ] && exit 0

# Anchored to command position — after a separator, not merely after a space — so
# `echo "run gh pr merge"` and `grep -r "git push" .` are not invocations.
# [;&|(] covers `&&` and `||` too.
MTK_PROMPT_CAPABLE='(^|[;&|(])[[:space:]]*(gh[[:space:]]+(pr[[:space:]]+(merge|create)|release[[:space:]]+create)|git[[:space:]]+(push|rebase))([[:space:]]|$)'
INTERACTIVE_HINT='MTK_INTERACTIVE_GUARD=0 in .claude/settings.local.json env'

grep -qE "$MTK_PROMPT_CAPABLE" <<<"$COMMAND" || exit 0

# Judge each LINE on its own, and only lines where the command is at command
# position: the PR that introduced this check was blocked by its own
# `gh pr create --body "$(cat <<EOF ... )"`, whose prose carried "| tail -5".
MTK_HIT_LINE=""
MTK_MERGE_LINE=""
while IFS= read -r _line; do
  grep -qE "$MTK_PROMPT_CAPABLE" <<<"$_line" || continue
  # `--help` never prompts, so a help invocation on this line disqualifies it.
  grep -qE '(^|[[:space:]])(--help|-h)([[:space:]]|$)' <<<"$_line" && continue
  [ -n "$MTK_HIT_LINE" ] || MTK_HIT_LINE="$_line"
  if [ -z "$MTK_MERGE_LINE" ] \
    && grep -qE '(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' <<<"$_line"; then
    MTK_MERGE_LINE="$_line"
  fi
done <<MTK_LINES
$COMMAND
MTK_LINES

# Every prompt-capable mention was prose or a help invocation.
[ -n "$MTK_HIT_LINE" ] || exit 0

# Block A: `gh pr merge` with no delete-branch decision. --squash/--merge/--rebase
# leave the branch question open, so gh prompts after the merge already landed.
if [ -n "$MTK_MERGE_LINE" ] \
  && ! grep -qE '(^|[[:space:]])--(no-)?delete-branch([[:space:]]|$)' <<<"$MTK_MERGE_LINE"; then
  mtk_deny - "$INTERACTIVE_HINT" <<'MTK_BLOCK_A'
BLOCKED (S4.12): `gh pr merge` without a delete-branch decision prompts after the merge
has already landed, then hangs until the Bash timeout with no visible output.

Add --delete-branch (or --no-delete-branch) and redirect stdin:

  gh pr merge <n> --squash --delete-branch < /dev/null

Note the merge itself may still succeed while the command appears to hang — check
`gh pr view <n> --json state` before retrying, so you do not act on a merge that landed.
MTK_BLOCK_A
fi

# Block B: prompt-capable command piped into tail/head, which buffer until EOF so
# the blocking prompt never reaches the transcript.
if grep -qE '\|[[:space:]]*(tail|head)([[:space:]]|$)' <<<"$MTK_HIT_LINE"; then
  mtk_deny - "$INTERACTIVE_HINT" <<'MTK_BLOCK_B'
BLOCKED (S4.12): piping a prompt-capable command through tail/head hides the prompt that
blocks it — tail buffers until EOF, so a waiting command reads as "(No output)".

Drop the pipe and let the command stream:

  gh pr merge <n> --squash --delete-branch < /dev/null

Pipe-to-tail is fine for read-only commands (`git log`, `gh pr view`), just not for ones
that can stop and ask a question.
MTK_BLOCK_B
fi

# Allow everything else
exit 0
