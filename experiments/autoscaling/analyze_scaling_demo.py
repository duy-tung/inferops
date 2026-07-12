#!/usr/bin/env python3
"""IO-T009 H-AS-2 analysis: before(1 replica)/after(2 replicas) comparison
from inferbench's own client-observed events.jsonl. No capacity fitting --
just arithmetic on measured request outcomes (offered rate, goodput,
shed/error fraction, wall time), plus the SAME seed used both times so the
per-request arrival schedule and generated payload sizes are identical
(inferbench's own workload_ref.seed determinism), isolating replica_count as
the one declared variable."""
import argparse
import json


def load_events(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def summarize(events):
    n = len(events)
    ok = sum(1 for e in events if e["status"] == "ok")
    shed = sum(1 for e in events if e.get("shed"))
    err = sum(1 for e in events if e["status"] not in ("ok", "shed"))
    if n == 0:
        return {"n": 0}
    send_times = sorted(e["send_ts"] for e in events)
    end_times = sorted(e["end_ts"] for e in events if e.get("end_ts"))

    def parse(s):
        import datetime
        return datetime.datetime.strptime(s.rstrip("Z"), "%Y-%m-%dT%H:%M:%S.%f")

    wall_s = (parse(end_times[-1]) - parse(send_times[0])).total_seconds() if end_times else None
    return {
        "n": n,
        "ok": ok,
        "shed": shed,
        "error": err,
        "ok_frac": round(ok / n, 4),
        "shed_frac": round(shed / n, 4),
        "error_frac": round(err / n, 4),
        "wall_s": round(wall_s, 3) if wall_s else None,
        "goodput_rps": round(ok / wall_s, 3) if wall_s else None,
        "offered_rps": round(n / wall_s, 3) if wall_s else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before-events", required=True)
    ap.add_argument("--after-events", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    args = ap.parse_args()

    before = summarize(load_events(args.before_events))
    after = summarize(load_events(args.after_events))

    fleetlab_fitted_per_replica_rps = 33.159
    fleetlab_g8_holdout_rel_error = -0.126  # reports/holdout-validation.md 2a, admission-sane-v1

    out = {
        "before_1_replica": before,
        "after_2_replicas": after,
        "fleetlab_comparison": {
            "fleetlab_fitted_per_replica_capacity_rps": fleetlab_fitted_per_replica_rps,
            "observed_before_goodput_rps_as_per_replica_capacity_proxy": before.get("goodput_rps"),
            "rel_diff_vs_fleetlab_pct": round(
                100 * (before.get("goodput_rps", 0) - fleetlab_fitted_per_replica_rps) / fleetlab_fitted_per_replica_rps, 2
            ) if before.get("goodput_rps") else None,
            "predicted_2_replica_goodput_rps_if_linear": round(before.get("goodput_rps", 0) * 2, 3) if before.get("goodput_rps") else None,
            "observed_2_replica_goodput_rps": after.get("goodput_rps"),
            "linear_scaling_rel_diff_pct": round(
                100 * (after.get("goodput_rps", 0) - before.get("goodput_rps", 0) * 2) / (before.get("goodput_rps", 0) * 2), 2
            ) if before.get("goodput_rps") and after.get("goodput_rps") else None,
        },
    }
    json.dump(out, open(args.out_json, "w"), indent=2)

    lines = []
    lines.append("# H-AS-2 scaling demonstration — before/after summary (measured, not simulated)\n")
    lines.append("| | BEFORE (1 replica) | AFTER (2 replicas) |")
    lines.append("|---|---|---|")
    for k in ["n", "ok", "shed", "error", "ok_frac", "shed_frac", "error_frac", "wall_s", "offered_rps", "goodput_rps"]:
        lines.append(f"| {k} | {before.get(k)} | {after.get(k)} |")
    lines.append("\n## fleetlab comparison\n")
    for k, v in out["fleetlab_comparison"].items():
        lines.append(f"- **{k}**: {v}")
    open(args.out_md, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
