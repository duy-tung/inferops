#!/usr/bin/env python3
"""IO-T009 signal poller.

Polls real Prometheus (never simulated) for the three Contract-2 candidate
autoscaling signals plus request/shed rates, and polls `docker stats` for a
CPU-utilization proxy (explicitly a compose/mock-substrate proxy, not a real
Kubernetes cgroup-limit-relative utilization figure -- see
experiments/autoscaling/report.md's honesty note), once per --interval
seconds for --duration seconds. Writes one CSV row per sample. Used by
run-signal-comparison.sh and run-scaling-demo.sh; not itself a capacity
model -- it only records what the running system reports.
"""
import argparse
import csv
import datetime
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import json


def prom_instant(prom_url, query):
    url = prom_url.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            data = json.load(resp)
    except Exception as e:
        return None, str(e)
    result = data.get("data", {}).get("result", [])
    if not result:
        return 0.0, None
    try:
        return float(result[0]["value"][1]), None
    except (KeyError, ValueError, IndexError):
        return None, "unparseable result"


def docker_cpu_percent(container_names):
    """Returns {name: cpu_percent_float_or_None} via one `docker stats --no-stream` call."""
    if not container_names:
        return {}
    try:
        out = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{.Name}},{{.CPUPerc}}"] + container_names,
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return {n: None for n in container_names}
    result = {n: None for n in container_names}
    for line in out.stdout.strip().splitlines():
        parts = line.split(",")
        if len(parts) != 2:
            continue
        name, pct = parts
        name = name.lstrip("/")
        try:
            result[name] = float(pct.strip().rstrip("%"))
        except ValueError:
            pass
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=float, required=True, help="total poll duration, seconds")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--prom-url", default="http://127.0.0.1:9090")
    ap.add_argument("--job-regex", required=True, help="Prometheus job label regex scoping the gateway target(s) under test")
    ap.add_argument("--containers", default="", help="comma-separated docker container names to sample CPU% for")
    ap.add_argument("--out", required=True, help="output CSV path")
    args = ap.parse_args()

    containers = [c for c in args.containers.split(",") if c]
    fieldnames = [
        "elapsed_s", "wall_clock_utc",
        "queue_depth", "requests_in_flight",
        "token_rate_output_per_s", "token_rate_input_per_s",
        "goodput_2xx_rps", "shed_rps", "error_5xx_rps",
    ] + [f"cpu_pct_{c}" for c in containers]

    t0 = time.monotonic()
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        n = 0
        while True:
            elapsed = time.monotonic() - t0
            if elapsed > args.duration:
                break
            row = {
                "elapsed_s": round(elapsed, 3),
                "wall_clock_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
            }
            jr = args.job_regex
            qd, _ = prom_instant(args.prom_url, f'sum(inference_queue_depth{{job=~"{jr}"}})')
            inflight, _ = prom_instant(args.prom_url, f'sum(inference_requests_in_flight{{job=~"{jr}"}})')
            tok_out, _ = prom_instant(args.prom_url, f'sum(rate(inference_usage_tokens_total{{job=~"{jr}",direction="output"}}[10s]))')
            tok_in, _ = prom_instant(args.prom_url, f'sum(rate(inference_usage_tokens_total{{job=~"{jr}",direction="input"}}[10s]))')
            good, _ = prom_instant(args.prom_url, f'sum(rate(inference_requests_total{{job=~"{jr}",status_class="2xx"}}[10s]))')
            shed, _ = prom_instant(args.prom_url, f'sum(rate(inference_sheds_total{{job=~"{jr}"}}[10s]))')
            err5, _ = prom_instant(args.prom_url, f'sum(rate(inference_requests_total{{job=~"{jr}",status_class="5xx"}}[10s]))')
            row["queue_depth"] = qd
            row["requests_in_flight"] = inflight
            row["token_rate_output_per_s"] = tok_out
            row["token_rate_input_per_s"] = tok_in
            row["goodput_2xx_rps"] = good
            row["shed_rps"] = shed
            row["error_5xx_rps"] = err5

            cpu = docker_cpu_percent(containers)
            for c in containers:
                row[f"cpu_pct_{c}"] = cpu.get(c)

            w.writerow(row)
            f.flush()
            n += 1

            # Sleep until the next interval boundary (best-effort; docker
            # stats + N prometheus queries take non-zero wall time).
            next_at = t0 + n * args.interval
            sleep_for = next_at - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)

    print(f"wrote {n} samples to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
