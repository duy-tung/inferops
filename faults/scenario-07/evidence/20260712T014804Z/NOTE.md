Superseded — this is the run that surfaced the methodology bug described in `verdict.md`
("Methodology correction found and fixed before the results below"): every worker sent the
IDENTICAL fixture body, and mockengine's error injection is a deterministic hash of the request
(same request => same pass/fail outcome always), so this run shows 1261/1261 succeeding despite
`-error-rate=0.3` — not a real 30% sample, just one fixture's fixed fate. Fixed by varying the
prompt per request in `../20260712T014858Z/` and the final `../20260712T014939Z/` (which also
adds Part 2). Kept per the evidence rule "invalid runs are noted, never deleted."
