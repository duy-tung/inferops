Superseded by `../20260712T015439Z/`. This run's probe loop was sequential (one blocked probe
during the pause consumed the whole pause window, leaving only 1 sample inside it) — fixed to
launch each probe as an independent background job in the superseding run, which is what
`verdict.md` reports.
