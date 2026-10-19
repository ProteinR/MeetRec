#!/usr/bin/env python3
"""Measures running processes the same way, for before/after and MeetRec vs OBS.

Usage: python3 scripts/profile.py <seconds> <label> <process name substring>...

For every matching process, over the window: memory footprint (what Activity Monitor shows as
"Memory") at start, end and its peak since launch, CPU time used and the average CPU %, threads,
and idle wake-ups per second (how often the process wakes the CPU; matters for battery). Prints a
table and appends one JSON line per process to scripts/profile-results.jsonl.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime


def pids(pattern):
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        # By the executable's name, not the whole path ("Mos" must not match "VoiceMemos.app/...").
        if pattern.lower() in os.path.basename(comm).lower() and "profile.py" not in comm:
            result[int(pid)] = os.path.basename(comm)
    return result


def footprint(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    def mb(key):
        m = re.search(rf"{key}:\s+([\d.]+)\s*(KB|MB|GB)", out)
        if not m:
            return None
        value = float(m.group(1))
        return value / 1024 if m.group(2) == "KB" else value * 1024 if m.group(2) == "GB" else value
    return mb("phys_footprint"), mb("phys_footprint_peak")


def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = [float(p) for p in out.replace("-", ":").split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds


def top_stats(pid_list, seconds):
    """Threads and idle wake-ups over the window (top's second sample covers it)."""
    args = ["top", "-l", "2", "-s", str(seconds), "-stats", "pid,threads,idlew"]
    for pid in pid_list:
        args += ["-pid", str(pid)]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    sample = out.split("PID")[-1].splitlines()[1:]
    stats = {}
    for line in sample:
        fields = line.split()
        if len(fields) >= 3 and fields[0].isdigit():
            threads = int(re.sub(r"\D.*", "", fields[1]) or 0)
            stats[int(fields[0])] = (threads, int(re.sub(r"\D", "", fields[2]) or 0))
    return stats


def main():
    seconds = int(sys.argv[1])
    label = sys.argv[2]
    procs = {}
    for pattern in sys.argv[3:]:
        procs.update(pids(pattern))
    if not procs:
        sys.exit("no matching processes")
    start = {pid: (footprint(pid)[0], cpu_seconds(pid)) for pid in procs}
    began = time.time()
    stats = top_stats(list(procs), seconds)  # blocks for the window
    elapsed = time.time() - began
    rows = []
    for pid, name in procs.items():
        end_mb, peak_mb = footprint(pid)
        cpu_end = cpu_seconds(pid)
        cpu_used = (cpu_end - start[pid][1]) if cpu_end is not None and start[pid][1] is not None else None
        threads, wakeups = stats.get(pid, (None, None))
        row = {
            "time": datetime.now().isoformat(timespec="seconds"), "label": label, "process": name, "pid": pid,
            "window_s": round(elapsed, 1), "mem_start_mb": start[pid][0], "mem_end_mb": end_mb, "mem_peak_mb": peak_mb,
            "cpu_s": round(cpu_used, 3) if cpu_used is not None else None,
            "cpu_pct": round(cpu_used / elapsed * 100, 3) if cpu_used is not None else None,
            "threads": threads, "wakeups_per_s": round(wakeups / seconds, 1) if wakeups is not None else None,
        }
        rows.append(row)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "profile-results.jsonl")
    with open(path, "a") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"{label} ({elapsed:.0f} s)")
    print(f"{'process':32} {'mem MB':>8} {'peak':>8} {'CPU %':>7} {'CPU s':>7} {'thr':>4} {'wake/s':>7}")
    for r in rows:
        print(f"{r['process'][:32]:32} {r['mem_end_mb'] or 0:8.1f} {r['mem_peak_mb'] or 0:8.1f} "
              f"{r['cpu_pct'] or 0:7.2f} {r['cpu_s'] or 0:7.2f} {r['threads'] or 0:4} {r['wakeups_per_s'] or 0:7.1f}")
    total_mem = sum(r["mem_end_mb"] or 0 for r in rows)
    total_cpu = sum(r["cpu_pct"] or 0 for r in rows)
    print(f"{'TOTAL':32} {total_mem:8.1f} {'':8} {total_cpu:7.2f}")


if __name__ == "__main__":
    main()
