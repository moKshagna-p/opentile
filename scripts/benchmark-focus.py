#!/usr/bin/env python3
r"""Collect macOS-observed focus separately from command exit; analyze JSONL runs.

Run from the repository root. Preparation (does not control any windows):
  mkdir -p .codex/performance
  swiftc -O scripts/focused-window.swift -o .codex/performance/focused-window
  .codex/performance/focused-window --self-test
  python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'

In an explicit GUI test session, run one window manager at a time. Do not replace
the installed app. Grant the observer Accessibility access manually if needed;
it never prompts. A stdin line requests one read-only query of the actual macOS
focused application/window (PID + CGWindowID), not the engine's focus cache.

Prepare .codex/performance/plan.json with alternating existing window identities:
  [{"expected":{"pid":123,"window_id":11},
    "command":["/absolute/path/to/aerospace","focus","--window-id","11"]},
   {"expected":{"pid":456,"window_id":22},
    "command":["/absolute/path/to/aerospace","focus","--window-id","22"]}]
Commands are argv arrays; no shell is used. For native-keyboard runs replace the
CLI commands with the same key injector and bindings for each compared manager.
Dispatch timing includes launching the trigger; command return is observed by
polling, not an exact process exit timestamp. Neither is a hardware key timestamp.
Do not call the CLI workload a native keyboard-focus or AeroSpace comparison.

Prepare metadata.json with build, revision, build_flags, signing, os, hardware,
apps, window_count, displays, configuration. Record the exact executable/config
and observer build, power conditions and app versions; use the same observer,
poll interval, apps/windows/displays and input method across compared builds.
Label vendored v0.21.3-Beta (9c53f4b) and any other stock release separately.

Then (output is exclusive; choose a new file for each build/session):
  python3 scripts/benchmark-focus.py collect --workload cli-focus \
    --observer .codex/performance/focused-window \
    --plan .codex/performance/plan.json --metadata .codex/performance/metadata.json \
    --output .codex/performance/candidate.jsonl
  python3 scripts/benchmark-focus.py analyze .codex/performance/candidate.jsonl

Defaults: 3 runs, 6 warmups + 40 measured trials each, 2 s deadlines, 5 ms polls.
Keep all raw trials. Compare per-run medians/p95 and failures against run-to-run
noise; these observations alone do not prove battery savings.

For engine diagnosis, launch the candidate with OPENTILE_TRACE_FOCUS=1 only in
that controlled session. In another terminal, capture its FocusStage events:
  /usr/bin/log stream --process OpenTile --style ndjson --signpost \
    --predicate 'eventMessage CONTAINS "focus_trace=1"' > .codex/performance/trace.ndjson
Pass --trace-log .codex/performance/trace.ndjson to analyze. These stages use the
engine's uptime clock and are correlated only within (processID, trace ID), not
automatically joined to collector timestamps. session_complete means normal
session return; queued AX work may run later or be cancelled. target_selected
records model focus changes including native synchronization and callbacks.
No trace event establishes OS-observed focus. Collect headline runs with tracing
off, then repeat with tracing on for diagnosis; logging itself has a cost.
"""
import argparse
from collections import Counter, defaultdict
import json
import hashlib
import math
from pathlib import Path
import re
import selectors
import statistics
import subprocess
import sys
import time


def identity(value):
    if not isinstance(value, dict):
        raise ValueError('Expected a window identity object')
    for key in ('pid', 'window_id'):
        if type(value.get(key)) is not int or value[key] <= 0:
            raise ValueError(f'{key} must be a positive integer')
    return {key: value[key] for key in ('pid', 'window_id')}


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('Use a finite positive number')
    return number


def percentile(values, percent):
    """Nearest rank, so p95 is the maximum for fewer than 20 successes."""
    if not values:
        return None
    return sorted(values)[max(0, math.ceil(percent / 100 * len(values)) - 1)]


def timing(values):
    return {'count': len(values), 'median_ms': statistics.median(values) if values else None,
            'p95_ms': percentile(values, 95)}


class Observer:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def query(self, deadline_ns):
        started = time.monotonic_ns()
        self.process.stdin.write(b'query\n')
        # A stalled or partial response must also obey the deadline.
        data = bytearray()
        while len(data) < 4096:
            remaining = (deadline_ns - time.monotonic_ns()) / 1e9
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError('observer_timeout')
            chunk = self.process.stdout.read(4096 - len(data))
            if not chunk:
                raise RuntimeError('observer_exited')
            data.extend(chunk)
            if data.endswith(b'\n'):
                value = json.loads(data)
                if not isinstance(value, dict):
                    raise ValueError('Observer response must be an object')
                if 'error' in value:
                    if not isinstance(value['error'], str):
                        raise ValueError('Observer error must be a string')
                    value = {'error': value['error']}
                else:
                    value = identity(value)
                return {'start_ns': started, 'end_ns': time.monotonic_ns(), **value}
        raise ValueError('Observer response exceeds 4096 bytes')

    def close(self):
        self.selector.close()
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()


def trial(observer, step, timeout, interval, clock=time.monotonic_ns, sleep=time.sleep,
          launch=subprocess.Popen):
    expected = identity(step['expected'])
    sample = {'expected': expected, 'before': None, 'observations': [],
              'dispatch_ns': None, 'command_return_observed_ns': None, 'command_exit_code': None,
              'focus_observed_ns': None, 'deadline_ns': None, 'status': 'precondition_failed'}
    process = None
    try:
        before = observer.query(clock() + int(timeout * 1e9))
        sample['before'] = before
        if 'error' in before or identity(before) == expected:
            sample['error'] = before.get('error', 'target_already_focused')
            return sample
        start = clock()
        sample['dispatch_ns'] = start
        deadline = start + int(timeout * 1e9)
        sample['deadline_ns'] = deadline
        process = launch(step['command'], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while clock() < deadline:
            code = process.poll()
            if code is not None and sample['command_return_observed_ns'] is None:
                sample['command_return_observed_ns'] = clock()
                sample['command_exit_code'] = code
            if code is not None and code != 0:
                sample['status'] = 'command_failed'
                return sample
            if sample['focus_observed_ns'] is None:
                observation = observer.query(deadline)
                sample['observations'].append(observation)
                if ('error' not in observation and identity(observation) == expected
                        and observation['end_ns'] <= deadline):
                    sample['focus_observed_ns'] = observation['end_ns']
            if sample['focus_observed_ns'] is not None and code == 0:
                sample['status'] = 'success'
                return sample
            sleep(min(interval, max(0, (deadline - clock()) / 1e9)))
        sample['status'] = 'timeout'
    except TimeoutError as error:
        sample.update(status='observer_timeout', error=str(error))
    except (OSError, RuntimeError, ValueError) as error:
        sample.update(status='error', error=str(error))
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
        sample['finished_ns'] = clock()
    return sample


def collect(args):
    plan = json.loads(args.plan.read_text())
    if not isinstance(plan, list) or not plan:
        raise ValueError('Plan must be a nonempty list of {expected, command} steps')
    for step in plan:
        identity(step['expected'])
        if (not isinstance(step['command'], list) or not step['command']
                or any(not isinstance(arg, str) or not arg for arg in step['command'])):
            raise ValueError('Each command must be a nonempty argv list')
    metadata = json.loads(args.metadata.read_text())
    for key in ('build', 'revision', 'build_flags', 'signing', 'os', 'hardware', 'apps',
                'window_count', 'displays', 'configuration'):
        if key not in metadata or metadata[key] in (None, '', []):
            raise ValueError(f'Metadata requires {key}')
    if min(args.runs, args.iterations) < 1 or args.warmup < 0:
        raise ValueError('Use runs/iterations >= 1 and warmup >= 0')
    # Exclusive creation protects previous raw evidence from accidental overwrite.
    with args.output.open('x') as output:
        def write(row):
            output.write(json.dumps(row, sort_keys=True) + '\n')
            output.flush()
        write({'kind': 'metadata', 'schema': 1, 'workload': args.workload, 'metadata': metadata,
               'observer': str(args.observer.resolve()), 'plan': plan, 'runs': args.runs,
               'observer_sha256': hashlib.sha256(args.observer.read_bytes()).hexdigest(),
               'collector_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'iterations': args.iterations, 'warmup': args.warmup, 'timeout_s': args.timeout,
               'interval_s': args.interval, 'clock': 'python_monotonic_ns',
               'observer_boundary': 'query round trip including IPC and Accessibility'})
        for run in range(1, args.runs + 1):
            observer = Observer([str(args.observer.resolve())])
            try:
                for index in range(args.warmup + args.iterations):
                    step = plan[index % len(plan)]
                    sample = trial(observer, step, args.timeout, args.interval)
                    write({'kind': 'sample', 'run': run, 'index': index,
                           'warmup': index < args.warmup, **sample})
                    # A broken protocol cannot safely correlate the next query.
                    if sample['status'] in ('error', 'observer_timeout'):
                        observer.close()
                        observer = Observer([str(args.observer.resolve())])
            finally:
                observer.close()


def summarize(rows, warmup=False):
    groups = defaultdict(list)
    for row in rows:
        if row.get('kind') == 'sample' and row['warmup'] == warmup:
            groups[row['run']].append(row)
    result = []
    for run, samples in sorted(groups.items()):
        focus, command, queries = [], [], []
        for sample in samples:
            for query in [sample['before'], *sample['observations']]:
                if query is None:
                    continue
                if query['end_ns'] < query['start_ns']:
                    raise ValueError('Observer timing is reversed')
                queries.append((query['end_ns'] - query['start_ns']) / 1e6)
            if sample['status'] != 'success':
                continue
            observed = sample['focus_observed_ns']
            start = sample['dispatch_ns']
            returned = sample['command_return_observed_ns']
            if (sample['command_exit_code'] != 0 or observed is None or returned is None
                    or start is None or min(observed, returned) < start
                    or identity(sample['before']) == identity(sample['expected'])
                    or not any('error' not in query and identity(query) == identity(sample['expected'])
                               and query['end_ns'] == observed and query['start_ns'] >= start
                               for query in sample['observations'])):
                raise ValueError('Success lacks an ordered macOS observation of the expected window')
            focus.append((observed - start) / 1e6)
            command.append((returned - start) / 1e6)
        result.append({'run': run, 'samples': len(samples), 'statuses': dict(Counter(
            sample['status'] for sample in samples)), 'focus_observed': timing(focus),
            'command_return_observed': timing(command), 'observer_round_trip': timing(queries)})
    return result


TRACE = re.compile(r'focus_trace=1 id=(\d+) stage=([a-z_]+) ns=(\d+) pid=(\d+) window=(\d+)')


def summarize_traces(rows):
    """Correlate by emitting process and trace ID, never by log delivery order."""
    groups = defaultdict(list)
    for row in rows:
        match = TRACE.search(row.get('eventMessage', ''))
        if match:
            trace_id, stage, ns, pid, window = match.groups()
            process = row.get('processID')
            if type(process) is not int or process <= 0:
                raise ValueError('Trace log requires emitting processID')
            groups[(process, trace_id)].append({'stage': stage, 'ns': int(ns),
                                                'pid': int(pid), 'window_id': int(window)})
    traces = []
    for (process, trace_id), events in sorted(groups.items()):
        events.sort(key=lambda event: event['ns'])
        stages = [event['stage'] for event in events]
        received = next((event['ns'] for event in events if event['stage'] == 'session_received'), None)
        complete = next((event['ns'] for event in events if event['stage'] == 'session_complete'), None)
        for event in events:
            event['since_start_ms'] = (event['ns'] - events[0]['ns']) / 1e6
        traces.append({'process_id': process, 'trace_id': trace_id, 'events': events,
                       'session_ms': (complete - received) / 1e6 if complete is not None
                       and received is not None and complete >= received else None,
                       'status': 'failed' if 'session_failed' in stages else
                       'complete' if received is not None and complete is not None and complete >= received
                       else 'incomplete',
                       'os_focus_verified': False})
    return traces


def read_jsonl(path, log_stream=False):
    with path.open() as source:
        for number, line in enumerate(source, 1):
            if log_stream and line.startswith('Filtering the log data using '):
                continue
            if line.strip():
                try:
                    row = json.loads(line)
                    if not isinstance(row, dict):
                        raise ValueError('Expected JSON object')
                    yield row
                except ValueError as error:
                    raise ValueError(f'{path}:{number}: {error}') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='mode', required=True)
    collector = commands.add_parser('collect', help='Run only in an explicit controlled GUI session')
    collector.add_argument('--plan', type=Path, required=True)
    collector.add_argument('--metadata', type=Path, required=True)
    collector.add_argument('--observer', type=Path, required=True)
    collector.add_argument('--output', type=Path, required=True)
    collector.add_argument('--workload', choices=['native-keyboard', 'cli-focus', 'opentile-action'], required=True)
    collector.add_argument('--runs', type=int, default=3)
    collector.add_argument('--iterations', type=int, default=40)
    collector.add_argument('--warmup', type=int, default=6)
    collector.add_argument('--timeout', type=positive, default=2)
    collector.add_argument('--interval', type=positive, default=0.005)
    analyzer = commands.add_parser('analyze', help='Report successes and failures for each labelled run')
    analyzer.add_argument('samples', type=Path)
    analyzer.add_argument('--trace-log', type=Path, help='Optional `log stream --style ndjson --signpost` output')
    args = parser.parse_args()
    if args.mode == 'collect':
        collect(args)
    else:
        rows = list(read_jsonl(args.samples))
        metadata = [row for row in rows if row.get('kind') == 'metadata']
        if len(metadata) != 1 or metadata[0].get('schema') != 1:
            raise ValueError('Expected exactly one schema-1 metadata record')
        runs = summarize(rows)
        expected = set(range(1, metadata[0]['runs'] + 1))
        complete = ({run['run'] for run in runs} == expected and
                    all(run['samples'] == metadata[0]['iterations'] for run in runs))
        summary = {'metadata': metadata[0], 'runs': runs, 'warmups': summarize(rows, warmup=True),
                   'collection_complete': complete, 'at_least_three_runs': len(runs) >= 3,
                   'note': 'Latency percentiles contain successful non-warmup trials only; inspect failures. '
                           'Command return is sampled and is not proof of focus. '
                           'Focus time is an upper bound at observer response; do not subtract query overhead.'}
        if args.trace_log:
            summary['engine_traces'] = summarize_traces(read_jsonl(args.trace_log, log_stream=True))
        print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        sys.exit(str(error))
