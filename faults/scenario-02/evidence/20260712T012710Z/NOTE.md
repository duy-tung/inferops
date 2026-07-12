Superseded by `../20260712T012838Z/`. This run used the gateway's default `-upstream-timeout=30s`,
which combined with the workload's `-itl=500ms` mock config to make 8/60 long completions time
out for a reason UNRELATED to the injected backend kill (a confound, documented in
`verdict.md`). The superseding run adds `-upstream-timeout=120s` to remove that confound.
