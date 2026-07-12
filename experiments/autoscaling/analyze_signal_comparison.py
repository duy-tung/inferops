#!/usr/bin/env python3
"""IO-T009 H-AS-1 analysis: turns signals.csv + events.jsonl + phases.json
into a per-phase table and a signal-detection comparison.

Detection rule is DELIBERATELY the same one fleetlab's FL-T006 discloses
(reports/autoscaling-signals.md ADR-0003: threshold = quiet-phase mean +
3*std, must sustain 5 consecutive seconds to "fire", drop to <= 0.7x
threshold for 5s to "clear") -- reusing a disclosed, already-published,
non-fitted statistical rule to describe OUR OWN measured data is
observational-analysis methodology, not a capacity model; this script fits
no capacity, predicts nothing, and computes no "should-scale-to" number --
that stays in fleetlab, per docs/scope.md.
"""
import argparse
import csv
import datetime
import json
import statistics
import sys


def parse_ts(s):
    # Both inferbench's events.jsonl timestamps and poll_signals.py's
    # wall_clock_utc use RFC3339 with a fixed 6-digit fractional second and
    # a literal "Z" suffix (Go's/Python's respective UTC formatters).
    s = s.rstrip("Z")
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc)


def load_events(path):
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            events.append(json.loads(line))
    return events


def load_signals(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows


SIGNAL_FIELDS = {
    "queue_depth": "queue_depth",
    "requests_in_flight": "requests_in_flight",
    "token_rate_output_per_s": "token_rate_output_per_s",
    "cpu_pct_gw": None,  # filled in from --containers naming at runtime
}


def to_float(v):
    if v is None or v == "":
        return None
    try:
        return float(v)
    except ValueError:
        return None


def detect_firing(samples, threshold, debounce_s=5.0, clear_frac=0.7):
    """samples: list of (elapsed_s, value) sorted by elapsed_s.
    Returns list of (fire_elapsed_s, clear_elapsed_s_or_None) episodes, using
    fleetlab's own debounce/hysteresis rule (ADR-0003): a crossing must hold
    continuously for >= debounce_s to count as fired; clears after holding
    <= clear_frac*threshold for >= debounce_s."""
    if threshold is None:
        return []
    episodes = []
    above_since = None
    below_since = None
    fired_at = None
    for t, v in samples:
        if v is None:
            continue
        if v > threshold:
            below_since = None
            if above_since is None:
                above_since = t
            if fired_at is None and (t - above_since) >= debounce_s:
                fired_at = above_since + debounce_s
        else:
            above_since = None
            if fired_at is not None:
                if v <= clear_frac * threshold:
                    if below_since is None:
                        below_since = t
                    if (t - below_since) >= debounce_s:
                        episodes.append((fired_at, below_since + debounce_s))
                        fired_at = None
                        below_since = None
                else:
                    below_since = None
    if fired_at is not None:
        episodes.append((fired_at, None))
    return episodes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--signals-csv", required=True)
    ap.add_argument("--phases-json", required=True)
    ap.add_argument("--events-jsonl", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    args = ap.parse_args()

    events = load_events(args.events_jsonl)
    events.sort(key=lambda e: e["send_ts"])
    t0 = parse_ts(events[0]["scheduled_send_ts"])

    phases = json.load(open(args.phases_json))

    rows = load_signals(args.signals_csv)
    for r in rows:
        wc = r["wall_clock_utc"]
        r["_t"] = parse_ts(wc)
        r["_elapsed"] = (r["_t"] - t0).total_seconds()

    cpu_fields = [k for k in rows[0].keys() if k.startswith("cpu_pct_")] if rows else []

    def phase_of(elapsed):
        for p in phases:
            if p["start_s"] <= elapsed < p["end_s"]:
                return p["phase"]
        return None

    # --- per-phase signal + client-truth stats ---
    phase_stats = {}
    for p in phases:
        pid = p["phase"]
        sig_rows = [r for r in rows if r["_elapsed"] >= p["start_s"] and r["_elapsed"] < p["end_s"]]
        ev_in_phase = [e for e in events if p["start_s"] <= (parse_ts(e["send_ts"]) - t0).total_seconds() < p["end_s"]]
        n_ok = sum(1 for e in ev_in_phase if e["status"] == "ok")
        n_shed = sum(1 for e in ev_in_phase if e.get("shed"))
        n_total = len(ev_in_phase)
        dur = p["end_s"] - p["start_s"]

        def mean_of(field):
            vals = [to_float(r[field]) for r in sig_rows]
            vals = [v for v in vals if v is not None]
            return round(statistics.mean(vals), 3) if vals else None

        def max_of(field):
            vals = [to_float(r[field]) for r in sig_rows]
            vals = [v for v in vals if v is not None]
            return round(max(vals), 3) if vals else None

        stat = {
            "phase": pid, "label": p["label"], "offered_rps": p["offered_rps"],
            "duration_s": dur,
            "client_observed_offered_rps": round(n_total / dur, 3) if dur else None,
            "client_observed_goodput_rps": round(n_ok / dur, 3) if dur else None,
            "client_observed_shed_frac": round(n_shed / n_total, 4) if n_total else None,
            "queue_depth_mean": mean_of("queue_depth"), "queue_depth_max": max_of("queue_depth"),
            "in_flight_mean": mean_of("requests_in_flight"), "in_flight_max": max_of("requests_in_flight"),
            "token_rate_out_mean": mean_of("token_rate_output_per_s"),
            "prom_goodput_mean": mean_of("goodput_2xx_rps"),
            "prom_shed_rps_mean": mean_of("shed_rps"),
        }
        for cf in cpu_fields:
            stat[f"{cf}_mean"] = mean_of(cf)
            stat[f"{cf}_max"] = max_of(cf)
        phase_stats[pid] = stat

    # --- detection: use phase 1 (quiet) as the calibration window, fleetlab's own rule ---
    p1 = next(p for p in phases if p["phase"] == 1)
    calib_rows = [r for r in rows if p1["start_s"] <= r["_elapsed"] < p1["end_s"]]

    def calib_threshold(field):
        vals = [to_float(r[field]) for r in calib_rows]
        vals = [v for v in vals if v is not None]
        if not vals:
            return None
        mean = statistics.mean(vals)
        std = statistics.pstdev(vals) if len(vals) > 1 else 0.0
        return mean + 3 * std

    knee_onset_s = next(p for p in phases if p["phase"] == 3)["start_s"]

    detection = {}
    fields_to_detect = ["queue_depth", "requests_in_flight", "token_rate_output_per_s"] + cpu_fields
    for field in fields_to_detect:
        thr = calib_threshold(field)
        series = sorted(((r["_elapsed"], to_float(r[field])) for r in rows), key=lambda x: x[0])
        episodes = detect_firing(series, thr)
        first_fire = episodes[0][0] if episodes else None
        detection[field] = {
            "calib_threshold": round(thr, 4) if thr is not None else None,
            "episodes": [(round(a, 2), round(b, 2) if b else None) for a, b in episodes],
            "first_fire_elapsed_s": round(first_fire, 2) if first_fire is not None else None,
            "lag_vs_knee_onset_s": round(first_fire - knee_onset_s, 2) if first_fire is not None else None,
            "fired_before_knee_false_early": bool(first_fire is not None and first_fire < knee_onset_s),
        }

    out = {
        "workload_start_utc": t0.isoformat(),
        "knee_onset_elapsed_s": knee_onset_s,
        "phase_stats": phase_stats,
        "detection": detection,
    }
    json.dump(out, open(args.out_json, "w"), indent=2)

    # --- markdown summary ---
    lines = []
    lines.append("# H-AS-1 signal-comparison — per-phase summary (measured, not simulated)\n")
    lines.append(f"Workload start (UTC): `{t0.isoformat()}`. True knee onset (phase 3 start): elapsed {knee_onset_s}s.\n")
    lines.append("| Phase | Offered rps (planned) | Offered rps (client-observed) | Goodput rps (client-observed) | Shed frac | queue_depth mean/max | in_flight mean/max | token_rate_out mean |" + "".join(f" {cf} mean/max |" for cf in cpu_fields))
    lines.append("|---|---|---|---|---|---|---|---|" + "---|" * len(cpu_fields))
    for p in phases:
        s = phase_stats[p["phase"]]
        cpu_cells = " | ".join(f"{s.get(cf+'_mean')}/{s.get(cf+'_max')}" for cf in cpu_fields)
        lines.append(
            f"| {s['phase']} ({s['label']}) | {s['offered_rps']} | {s['client_observed_offered_rps']} | "
            f"{s['client_observed_goodput_rps']} | {s['client_observed_shed_frac']} | "
            f"{s['queue_depth_mean']}/{s['queue_depth_max']} | {s['in_flight_mean']}/{s['in_flight_max']} | "
            f"{s['token_rate_out_mean']} | " + cpu_cells + " |"
        )
    lines.append("\n## Detection (fleetlab ADR-0003 rule: calib-window mean+3*std threshold, 5s debounce, 0.7x/5s clear)\n")
    lines.append("| Signal | calib threshold | first-fire elapsed_s | lag vs knee onset (90s) | fired before knee (false/early)? | episodes |")
    lines.append("|---|---|---|---|---|---|")
    for field, d in detection.items():
        lines.append(
            f"| {field} | {d['calib_threshold']} | {d['first_fire_elapsed_s']} | {d['lag_vs_knee_onset_s']} | "
            f"{d['fired_before_knee_false_early']} | {d['episodes']} |"
        )
    open(args.out_md, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
