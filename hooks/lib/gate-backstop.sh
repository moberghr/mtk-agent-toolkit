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
# Requires hooks/lib/hook-io.sh (mtk_repo_root, mtk_repo_relative_path).

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
  case "${1##*/}" in
    grep|egrep|fgrep|rg|ack|ag|echo|printf|cat|head|tail|less|more|strings|wc| \
    awk|gawk|mawk|nawk|sort|uniq|cut|tr|diff|comm|jq|ls|stat|file|test|'['|true|false|type|which) return 0 ;;
  esac
  return 1
}

# Drop the first word of $rest (and its leading whitespace); refresh $word.
mtk_bs_shift_word() {
  rest="${rest#"$word"}"; rest="${rest#"${rest%%[![:space:]]*}"}"; word="${rest%%[[:space:]]*}"
}

# One separator-free segment in, the text to judge out (nothing if exempt).
mtk_bs_judge_segment() {
  local seg="$1" rest word inner
  case "$seg" in
    *'$('*|*'`'*)
      printf '%s' "$seg" | sed 's/\$(/\n/g; s/)/\n/g; s/`/\n/g' \
        | while IFS= read -r inner || [ -n "$inner" ]; do
            [ -n "${inner//[[:space:]]/}" ] && mtk_bs_judge_segment "$inner"
          done
      return 0 ;;
  esac
  rest="${seg#"${seg%%[![:space:]]*}"}"
  word="${rest%%[[:space:]]*}"
  # Peel assignments, control words, and wrappers until a real command word remains.
  while [ -n "$word" ]; do
    case "$word" in
      *=*|do|done|then|else|elif|fi|if|while|until|'!'|'{'|'}'|'('|')'|time|nice|nohup|command|builtin|exec)
        mtk_bs_shift_word ;;
      xargs)
        mtk_bs_shift_word
        # Drop xargs' own flags; -I/-n/-P/-L/-d/-s/-E take a separate argument.
        while [ -n "$word" ]; do
          case "$word" in
            -I|-n|-P|-L|-d|-s|-E) mtk_bs_shift_word; mtk_bs_shift_word ;;
            -*) mtk_bs_shift_word ;;
            *) break ;;
          esac
        done ;;
      git)
        mtk_bs_shift_word
        while [ -n "$word" ]; do
          case "$word" in
            -C|-c) mtk_bs_shift_word; mtk_bs_shift_word ;;
            --no-pager|--paginate|-p) mtk_bs_shift_word ;;
            *) break ;;
          esac
        done
        case "$word" in
          grep|log|diff|show|status|blame|ls-files|rev-parse|describe|shortlog|cat-file|rev-list|name-rev) return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
      find)
        # `find … -exec <cmd> …`: judge <cmd>. `-delete` and anything else: judge whole.
        case "$rest" in
          *' -exec '*|*' -execdir '*)
            inner="${rest#* -exec}"; inner="${inner#dir}"
            mtk_bs_judge_segment "$inner"; return 0 ;;
          *) printf '%s\n' "$seg"; return 0 ;;
        esac ;;
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
            mtk_bs_executable_text "$inner"; return 0 ;;
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
  [ -n "$word" ] || return 0
  mtk_bs_readonly_word "$word" || printf '%s\n' "$seg"
}

mtk_bs_executable_text() {
  # `|| [ -n "$_mtk_bs_seg" ]`: the input has no trailing newline, so the final (often
  # only) segment leaves `read` at EOF with a non-zero status. Without this the loop
  # body never runs and the function returns nothing — which reads as "no executable
  # text", i.e. the gate silently allows everything.
  printf '%s' "${1-}" | tr ';|&' '\n\n\n' | while IFS= read -r _mtk_bs_seg || [ -n "$_mtk_bs_seg" ]; do
    mtk_bs_judge_segment "$_mtk_bs_seg"
  done
}

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
  if mtk_bs_has_destructive_sql "$exec_text"; then
    printf 'Destructive database operation detected. Use a migration instead.\n'; return 0
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
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
  if grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(\.|/|~|\$HOME)' <<<"$exec_text"; then
    printf 'Recursive force-delete on broad path. Be more specific.\n'; return 0
  fi
  return 1
}
