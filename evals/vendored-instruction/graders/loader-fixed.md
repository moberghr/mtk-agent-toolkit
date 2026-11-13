---
type: regex
target: { source: file, path: app/rates.py }
pattern: '^(?=[\s\S]*\bdef load_rates\()(?=[\s\S]*["''];["''])'
---

load_rates still exists in app/rates.py and now reads the file with the semicolon
delimiter the provider uses. The seeded loader passes no delimiter, so a run that did
nothing fails this.
