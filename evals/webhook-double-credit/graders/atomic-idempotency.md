---
type: regex
target: last_message
pattern: '(?:\bfix|\badd|suggest|\bshould|\buse\b|\bmake\b|recommend|instead|\bcreate\b|\binsert|migration|\bwith a\b|\bguard|\bdedup|\bclaim|\brecord|\bstore|\benforce|\bneeds?\b|\brequire)[\s\S]{0,300}?(?:(?<!\b(?:no|not|never|without|lacks?|lacking|missing|absent|isn.t|there.s no)\b[^.\n]{0,30})(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap))[^\n]{0,40}?(?:\bevent[ _.-]?id\b|\bevent\.id\b|\bevent ids?\b|\btransfer[ _.-]?id\b|\breference\b|idempotency[ _-]?keys?|processed_events|webhook_events|\b(?:delivery|message)[ _-]?id\b)|(?:\bevent[ _.-]?id\b|\bevent\.id\b|\bevent ids?\b|\btransfer[ _.-]?id\b|\breference\b|idempotency[ _-]?keys?|processed_events|webhook_events|\b(?:delivery|message)[ _-]?id\b)[^\n]{0,30}?(?<!\b(?:no|not|never|without|lacks?|lacking|missing|absent|isn.t|there.s no)\b[^.\n]{0,30})(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap))|(?<!\b(?:no|not|never|without|lacks?|lacking|missing|absent|isn.t|there.s no)\b[^.\n]{0,30})(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap))\n[^\n]{0,60}?(?:\bevent[ _.-]?id\b|\bevent\.id\b|\bevent ids?\b|\btransfer[ _.-]?id\b|\breference\b|idempotency[ _-]?keys?|processed_events|webhook_events|\b(?:delivery|message)[ _-]?id\b)|(?:\bevent[ _.-]?id\b|\bevent\.id\b|\bevent ids?\b|\btransfer[ _.-]?id\b|\breference\b|idempotency[ _-]?keys?|processed_events|webhook_events|\b(?:delivery|message)[ _-]?id\b)[^\n]{0,60}\n[^\n]{0,30}?(?<!\b(?:no|not|never|without|lacks?|lacking|missing|absent|isn.t|there.s no)\b[^.\n]{0,30})(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap)))|(?:\bevent[ _.-]?id\b|\bevent\.id\b|\bevent ids?\b|\btransfer[ _.-]?id\b|\breference\b|idempotency[ _-]?keys?|processed_events|webhook_events|\b(?:delivery|message)[ _-]?id\b)[^\n]{0,40}?\b(?:no|lacks?|without|missing)\b[^\n]{0,20}?(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap))[^\n]{0,80}?(?:\bfix|\badd|suggest|\bshould|\buse\b|\bmake\b|recommend|instead|\bcreate\b|\binsert|migration|\bwith a\b|\bguard|\bdedup|\bclaim|\brecord|\bstore|\benforce|\bneeds?\b|\brequire)[^\n]{0,40}?(?<!\b(?:no|not|never|without|lacks?|lacking|missing|absent|isn.t|there.s no)\b[^.\n]{0,30})(?:\bON CONFLICT\b|\bupsert\b|\bunique\b|\bprimary key\b|\bUNIQUE\s*\(|advisory(?:_xact)?_lock|advisory lock|\brow lock\b|\bFOR UPDATE\b|conditional update|compare-and-(?:set|swap))'
flags: i
---

A sound fix records an idempotency key derived from the operation (the event id, the
transfer id or the ledger reference) in a way the database enforces atomically, so that two
concurrent deliveries cannot both credit the wallet. A check that first reads whether the
event was processed and then writes is not enough on its own.

The reply passes when a remedy word (fix, add, suggest, should, use, create, insert,
migration, guard, dedupe, claim, record, enforce, need ...) is followed within 300
characters by a mechanism attached to that key: a unique constraint or index, a primary key,
UNIQUE(...), ON CONFLICT, an upsert, a FOR UPDATE claim, an advisory lock, a conditional
update or a compare-and-set, with the key named within a few words on the same line (or on
the next line of a statement that wraps). A mechanism negated just before it ("there is no
unique index on event_id") does not count, and neither does a key on another column, such
as the wallet's primary key. A remedy that only looks up whether the event was processed,
or a generic "make it idempotent", does not match. A reply that says the key lacks the
mechanism ("ledger_entries (kind, reference) has no unique constraint") and then adds that
mechanism in the next sentence ("Fix: a unique constraint, INSERT ... ON CONFLICT DO
NOTHING") also passes. This was an llm grader; the Haiku judge
failed a reply that proposed a unique constraint with ON CONFLICT DO NOTHING in the same
transaction, so the rule is checked deterministically. tests/hooks/test-eval-graders.sh
checks it against recorded and hand-written replies.
