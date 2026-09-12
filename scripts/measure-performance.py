#!/usr/bin/env python3
"""Sample an OpenTile PID (including its embedded engine) without Xcode.

Run the same release build three times, changing --scenario and app state:
  python3 scripts/measure-performance.py --pid PID --scenario paused > paused.csv
  python3 scripts/measure-performance.py --pid PID --scenario idle > idle.csv
  python3 scripts/measure-performance.py --pid PID --scenario gestures > gestures.csv
Pause gestures for paused; enable and leave the trackpad untouched for idle;
repeat move/resize/draw gestures for gestures. Defaults to 60 seconds. Keep the
same apps, power source and display setup between runs. CPU is interval CPU time
as a percentage of one core; RSS is resident memory, not total allocation.
This measures the specified process, not unrelated apps or battery consumption.
"""
import argparse
import csv
import subprocess
import sys
import time


def cpu_seconds(value):
    days, sep, clock = value.partition('-')
    if not sep:
        clock, days = days, '0'
    fields = [float(part) for part in clock.split(':')]
    total = 0.0
    for part in fields:
        total = total * 60 + part
    return int(days) * 86400 + total


def sample(pid):
    result = subprocess.run(
        ['/bin/ps', '-p', str(pid), '-o', 'time=', '-o', 'rss='],
        capture_output=True, text=True, check=False,
    )
    fields = result.stdout.split()
    if result.returncode or len(fields) != 2:
        raise RuntimeError('Target process exited or cannot be sampled')
    return time.monotonic(), cpu_seconds(fields[0]), int(fields[1]) / 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--scenario', choices=['paused', 'idle', 'gestures'], required=True)
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--interval', type=float, default=1)
    args = parser.parse_args()
    if args.pid <= 0 or not (0 < args.interval <= args.duration < float('inf')):
        parser.error('Use a positive PID and 0 < interval <= duration < infinity')
    previous = sample(args.pid)
    start = previous[0]
    writer = csv.writer(sys.stdout)
    writer.writerow(['scenario', 'elapsed_seconds', 'cpu_percent_one_core', 'rss_mib'])
    while previous[0] - start < args.duration:
        time.sleep(min(args.interval, max(0, args.duration - (previous[0] - start))))
        current = sample(args.pid)
        cpu = max(0, current[1] - previous[1]) / (current[0] - previous[0]) * 100
        writer.writerow([args.scenario, f'{current[0] - start:.3f}', f'{cpu:.3f}', f'{current[2]:.3f}'])
        sys.stdout.flush()
        previous = current


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
