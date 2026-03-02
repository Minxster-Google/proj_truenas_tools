#!/bin/bash
set -euo pipefail

# HBA pattern analyzer for TrueNAS kernel logs.
#
# Usage examples:
#   ./hba_pattern_report.sh
#   ./hba_pattern_report.sh --since "2026-03-01 00:00:00"
#   ./hba_pattern_report.sh --latest-bursts 12

SINCE=""
LATEST_BURSTS=8
YEAR="$(date +%Y)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="${2:-}"
      shift 2
      ;;
    --latest-bursts)
      LATEST_BURSTS="${2:-8}"
      shift 2
      ;;
    --year)
      YEAR="${2:-$YEAR}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--since \"YYYY-MM-DD [HH:MM:SS]\"] [--latest-bursts N] [--year YYYY]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

python3 - "$SINCE" "$LATEST_BURSTS" "$YEAR" <<'PY'
import gzip
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

since_raw = sys.argv[1]
latest_bursts = int(sys.argv[2])
year = int(sys.argv[3])

files = [
    Path("/var/log/kern.log.7.gz"),
    Path("/var/log/kern.log.6.gz"),
    Path("/var/log/kern.log.5.gz"),
    Path("/var/log/kern.log.4.gz"),
    Path("/var/log/kern.log.3.gz"),
    Path("/var/log/kern.log.2.gz"),
    Path("/var/log/kern.log.1"),
    Path("/var/log/kern.log"),
]

if since_raw:
    try:
        since = datetime.fromisoformat(since_raw)
    except ValueError:
        try:
            since = datetime.strptime(since_raw, "%Y-%m-%d")
        except ValueError:
            print(f"Invalid --since value: {since_raw}", file=sys.stderr)
            sys.exit(2)
else:
    since = None

month_map = {m: i for i, m in enumerate([
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
], 1)}

rx_ts = re.compile(r"^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d\d:\d\d:\d\d)\s+")
rx_slot = re.compile(r"sd\s+(\d+:\d+:\d+:\d+):")
rx_dev = re.compile(r"dev\s+(sd[a-z]+)")
rx_log = re.compile(r"log_info\(0x([0-9a-fA-F]+)\)")
rx_cdb = re.compile(r"CDB:\s+([A-Za-z]+)\(")

events = []
cdb_ops = Counter()

def open_log(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", errors="ignore")
    return path.open("r", errors="ignore")

for path in files:
    if not path.exists():
        continue
    with open_log(path) as f:
        for line in f:
            m = rx_ts.match(line)
            if not m:
                continue
            mon, day, tstr = m.groups()
            dt = datetime(year, month_map[mon], int(day), int(tstr[:2]), int(tstr[3:5]), int(tstr[6:]))
            if since and dt < since:
                continue

            msg = line.rstrip("\n")
            et = None
            if "Power-on or device reset occurred" in msg:
                et = "reset"
            elif "I/O error, dev" in msg:
                et = "io"
            elif "FAILED Result: hostbyte=DID_TIME_OUT" in msg:
                et = "timeout"
            elif "attempting task abort!" in msg:
                et = "abort_attempt"
            elif "task abort: SUCCESS" in msg:
                et = "abort_success"
            elif "No reference found at driver" in msg:
                et = "no_ref"
            elif "log_info(" in msg and "mpt3sas" in msg:
                et = "loginfo"

            cdbm = rx_cdb.search(msg)
            if cdbm:
                cdb_ops[cdbm.group(1)] += 1

            if not et:
                continue

            slot = None
            bay = None
            dev = None
            code = None

            sm = rx_slot.search(msg)
            if sm:
                slot = sm.group(1)
                parts = slot.split(":")
                if len(parts) == 4:
                    bay = parts[2]

            dm = rx_dev.search(msg)
            if dm:
                dev = dm.group(1)

            lm = rx_log.search(msg)
            if lm:
                code = "0x" + lm.group(1).lower()

            events.append((dt, et, slot, bay, dev, code))

if not events:
    print("No matching HBA/storage events found in parsed kern.log files.")
    sys.exit(0)

events.sort(key=lambda x: x[0])

print("== HBA Pattern Report ==")
print(f"Parsed range: {events[0][0]} -> {events[-1][0]}")
if since:
    print(f"Filter since: {since}")
print(f"Total matched events: {len(events)}")

counts = Counter(e[1] for e in events)
print("\n[Counts by event type]")
for key in ["reset", "io", "timeout", "abort_attempt", "abort_success", "no_ref", "loginfo"]:
    print(f"{key}: {counts.get(key, 0)}")

codes = Counter(e[5] for e in events if e[1] == "loginfo" and e[5])
print("\n[Top mpt3sas log_info codes]")
for code, n in codes.most_common(10):
    print(f"{code}: {n}")

print("\n[Daily recent summary: date reset io timeout loginfo]")
daily = defaultdict(lambda: Counter())
for dt, et, *_ in events:
    daily[dt.date()][et] += 1
for d in sorted(daily)[-14:]:
    c = daily[d]
    print(f"{d} {c['reset']} {c['io']} {c['timeout']} {c['loginfo']}")

print("\n[Top bays by reset count]")
for bay, n in Counter(e[3] for e in events if e[1] == "reset" and e[3]).most_common(12):
    print(f"bay {bay}: {n}")

print("\n[Top devices by I/O error count]")
for dev, n in Counter(e[4] for e in events if e[1] == "io" and e[4]).most_common(12):
    print(f"{dev}: {n}")

timeouts = [(dt, slot) for dt, et, slot, *_ in events if et == "timeout" and slot]
resets_by_slot = defaultdict(list)
for dt, et, slot, *_rest in events:
    if et == "reset" and slot:
        resets_by_slot[slot].append(dt)
for s in resets_by_slot:
    resets_by_slot[s].sort()

match_timeout_reset = 0
for tdt, slot in timeouts:
    for rdt in resets_by_slot.get(slot, []):
        if rdt < tdt:
            continue
        if (rdt - tdt).total_seconds() <= 120:
            match_timeout_reset += 1
        break

print("\n[Timeout coupling]")
print(f"Timeouts total: {len(timeouts)}")
print(f"Timeouts with same-slot reset <=120s: {match_timeout_reset}")

resets = [e for e in events if e[1] == "reset"]
bursts = []
if resets:
    start = last = resets[0][0]
    n = 1
    for r in resets[1:]:
        t = r[0]
        if (t - last).total_seconds() <= 120:
            n += 1
            last = t
        else:
            bursts.append((start, last, n))
            start = last = t
            n = 1
    bursts.append((start, last, n))

large = [b for b in bursts if b[2] >= 3]
print("\n[Burst stats: reset gap <=120s]")
print(f"All bursts: {len(bursts)}")
print(f"Bursts with >=3 events: {len(large)}")
if large:
    dur = [(b[1] - b[0]).total_seconds() for b in large]
    ev = [b[2] for b in large]
    dur_sorted = sorted(dur)
    ev_sorted = sorted(ev)
    mid_d = dur_sorted[len(dur_sorted)//2]
    mid_e = ev_sorted[len(ev_sorted)//2]
    print(f"Median burst duration (s): {mid_d:.1f}")
    print(f"Median events per burst: {mid_e}")
    print(f"Max events in one burst: {max(ev)}")

intra = []
for i in range(1, len(resets)):
    gap = (resets[i][0] - resets[i - 1][0]).total_seconds()
    if gap <= 120:
        intra.append(gap)
if intra:
    intra_sorted = sorted(intra)
    print(f"Median intra-burst reset interval (s): {intra_sorted[len(intra_sorted)//2]:.1f}")

print(f"\n[Latest {latest_bursts} bursts with >=3 events]")
for b in large[-latest_bursts:]:
    mins = (b[1] - b[0]).total_seconds() / 60.0
    print(f"{b[0]} -> {b[1]} | events={b[2]} | duration={mins:.1f}m")

if cdb_ops:
    print("\n[Top timed-out CDB operations seen]")
    for op, n in cdb_ops.most_common(6):
        print(f"{op}: {n}")
PY
