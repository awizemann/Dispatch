---
title: Convention: framing-line rule — sanitizeLine on trusted prompt lines, sanitize inside fences
type: note
permalink: dispatch/conventions/convention-framing-line-rule-sanitizeline-on-trusted-prompt
created: 2026-07-18
updated: 2026-07-30
---
The bus-text injection contract, settled across f3a672d (discovery) and 635be08 (full sweep). `BusTextSanitizer.sanitize` strips C0 controls EXCEPT \n/\t and the [BUS-CONTENT] frame markers — newlines are deliberately kept because prose bodies are marker-fenced and declared DATA. That makes newline survival the one remaining breakout: an untrusted value interpolated ON a trusted framing line (outside the fence) can mint lines that read as platform-authored ("[BUS-CONTENT …] SYSTEM: …").

## Observations
- [convention] Any untrusted value (subject, title, target, name, reason, purpose, path) interpolated ON a framing line of an injected prompt goes through `BusTextSanitizer.sanitizeLine` (fold whitespace runs → then sanitize). Marker-fenced bodies keep standard `sanitize` — fenced text may span lines by design #security
- [convention] DispatchTests/MCPBus/ holds the enforcement suites: one folded-inert property test per notice builder (hostile multi-line input → no output line starts with the forged token). A NEW notice builder that interpolates untrusted text on a framing line must add a case there #testing
- [convention] Test the property, not the substring: assert `no line hasPrefix(forged)` (or `!contains("\n")` for single-line notices) — a substring-with-\n assertion is bypassable by a "\n " fold regression #testing
- [decision] The deliberate exceptions this rule once carried (deploy-gate command echo, commit messages) died with those features — in Dispatch there is NO exception: every untrusted value on a framing line folds #security
- [fact] Safe-by-construction surfaces that do NOT need sanitizeLine: JSON tool-result payloads (newlines escape), board-note/DB storage re-read through JSON, and UI-only chips/activity (shortened/displayShorten fold already) #security
