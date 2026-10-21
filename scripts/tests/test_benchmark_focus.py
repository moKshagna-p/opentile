import copy
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('benchmark_focus', Path(__file__).parents[1] / 'benchmark-focus.py')
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)

A = {'pid': 10, 'window_id': 1}
B = {'pid': 10, 'window_id': 2}
C = {'pid': 20, 'window_id': 2}
STEP = {'expected': B, 'command': ['/fake/focus', '2']}


class Clock:
    def __init__(self):
        self.ns = 1_000_000

    def now(self):
        return self.ns

    def sleep(self, seconds):
        self.ns += int(seconds * 1e9)


class FakeObserver:
    def __init__(self, clock, windows):
        self.clock = clock
        self.windows = iter(windows)

    def query(self, deadline):
        start = self.clock.now()
        self.clock.ns += 1_000_000
        value = next(self.windows, A)
        if isinstance(value, Exception):
            raise value
        return {'start_ns': start, 'end_ns': self.clock.now(), **value}


class FakeProcess:
    def __init__(self, codes=(0,)):
        self.codes = iter(codes)
        self.code = None
        self.killed = False
        self.waited = False

    def poll(self):
        self.code = next(self.codes, self.code)
        return self.code

    def kill(self):
        self.killed = True

    def wait(self):
        self.waited = True


def run_trial(windows, codes=(0,), timeout=0.010):
    clock = Clock()
    process = FakeProcess(codes)
    sample = bench.trial(FakeObserver(clock, windows), STEP, timeout, 0.001,
                         clock=clock.now, sleep=clock.sleep, launch=lambda *a, **k: process)
    return sample, process


def sample_row(sample, run=1, warmup=False):
    return {'kind': 'sample', 'run': run, 'warmup': warmup, **sample}


def trace(stage, ns, trace_id=1, process=42, window=2):
    return {'processID': process, 'eventMessage':
            f'focus_trace=1 id={trace_id} stage={stage} ns={ns} pid=10 window={window}'}


class BenchmarkTests(unittest.TestCase):
    def test_identity_checks_pid_and_window_and_rejects_bad_values(self):
        self.assertNotEqual(bench.identity(B), bench.identity(C))
        for bad in ({'pid': True, 'window_id': 1}, {'pid': 1, 'window_id': 0}, [], None):
            with self.assertRaises(ValueError):
                bench.identity(bad)

    def test_command_return_is_not_focus_and_wrong_pid_is_not_success(self):
        sample, process = run_trial([A, A, C, B])
        self.assertEqual(sample['status'], 'success')
        self.assertGreater(sample['focus_observed_ns'], sample['command_return_observed_ns'])
        self.assertEqual(len(sample['observations']), 3)
        self.assertTrue(process.waited)
        self.assertFalse(process.killed)

    def test_focus_can_precede_command_return(self):
        sample, _ = run_trial([A, B, RuntimeError('unnecessary query after focus')], codes=(None, 0))
        self.assertEqual(sample['status'], 'success')
        self.assertLess(sample['focus_observed_ns'], sample['command_return_observed_ns'])

    def test_already_focused_and_permission_failure_do_not_dispatch(self):
        for window in (B, {'error': 'accessibility_permission_required'}):
            sample, process = run_trial([window])
            self.assertEqual(sample['status'], 'precondition_failed')
            self.assertIsNone(sample['dispatch_ns'])
            self.assertFalse(process.waited)

    def test_timeout_preserves_attempts_and_never_uses_return_as_focus(self):
        sample, _ = run_trial([A])
        self.assertEqual(sample['status'], 'timeout')
        self.assertEqual(sample['command_exit_code'], 0)
        self.assertIsNone(sample['focus_observed_ns'])
        self.assertTrue(sample['observations'])

    def test_nonzero_command_with_matching_focus_is_still_failure(self):
        sample, _ = run_trial([A, B], codes=(7,))
        self.assertEqual(sample['status'], 'command_failed')
        summary = bench.summarize([sample_row(sample)])[0]
        self.assertEqual(summary['focus_observed']['count'], 0)
        self.assertEqual(summary['statuses'], {'command_failed': 1})

    def test_hung_command_is_killed_and_reaped_even_if_focus_matches(self):
        sample, process = run_trial([A, B], codes=(None,))
        self.assertEqual(sample['status'], 'timeout')
        self.assertIsNotNone(sample['focus_observed_ns'])
        self.assertTrue(process.killed)
        self.assertTrue(process.waited)

    def test_query_past_deadline_is_not_success(self):
        sample, _ = run_trial([A, B], timeout=0.0005)
        self.assertEqual(sample['status'], 'timeout')
        self.assertIsNone(sample['focus_observed_ns'])

    def test_observer_timeout_before_dispatch_is_a_recorded_failure(self):
        class Stalled:
            def query(self, deadline):
                raise TimeoutError('observer_timeout')
        sample = bench.trial(Stalled(), STEP, 1, 0.001)
        self.assertEqual(sample['status'], 'observer_timeout')
        self.assertIsNone(sample['dispatch_ns'])
        self.assertEqual(bench.summarize([sample_row(sample)])[0]['samples'], 1)

    def test_launch_failure_is_recorded(self):
        def fail(*args, **kwargs):
            raise OSError('not executable')
        clock = Clock()
        sample = bench.trial(FakeObserver(clock, [A]), STEP, 1, 0.001, clock=clock.now, launch=fail)
        self.assertEqual(sample['status'], 'error')
        self.assertIn('not executable', sample['error'])

    def test_percentiles_empty_single_even_and_nearest_rank(self):
        self.assertEqual(bench.timing([]), {'count': 0, 'median_ms': None, 'p95_ms': None})
        self.assertEqual(bench.timing([9])['p95_ms'], 9)
        self.assertEqual(bench.timing([1, 3])['median_ms'], 2)
        self.assertEqual(bench.percentile(list(range(1, 101)), 95), 95)

    def test_warmups_and_failures_excluded_from_percentiles_but_counted(self):
        success, _ = run_trial([A, B])
        failure, _ = run_trial([A])
        result = bench.summarize([sample_row(success, warmup=True), sample_row(success),
                                  sample_row(failure), sample_row(failure, run=2)])
        self.assertEqual(result[0]['samples'], 2)
        self.assertEqual(result[0]['focus_observed']['count'], 1)
        self.assertEqual(result[0]['statuses'], {'success': 1, 'timeout': 1})
        self.assertIsNone(result[1]['focus_observed']['median_ms'])

    def test_analyzer_rejects_forged_identity_and_reversed_timing(self):
        sample, _ = run_trial([A, B])
        wrong_window = copy.deepcopy(sample)
        wrong_window['expected'] = C
        wrong_time = copy.deepcopy(sample)
        wrong_time['observations'][0]['end_ns'] = 0
        for bad in (wrong_window, wrong_time):
            with self.assertRaises(ValueError):
                bench.summarize([sample_row(bad)])

    def test_trace_correlation_sorting_and_async_request_after_session_complete(self):
        rows = [trace('native_request', 6_000_000), trace('session_complete', 4_000_000),
                trace('session_received', 1_000_000), trace('ax_queued', 3_000_000),
                trace('session_received', 2_000_000, process=43),
                trace('session_failed', 5_000_000, trace_id=2)]
        traces = bench.summarize_traces(rows)
        self.assertEqual(len(traces), 3)
        self.assertEqual(traces[0]['status'], 'complete')
        self.assertEqual(traces[0]['session_ms'], 3)
        self.assertEqual(traces[0]['events'][-1]['since_start_ms'], 5)
        self.assertFalse(traces[0]['os_focus_verified'])
        self.assertEqual(traces[1]['status'], 'failed')
        self.assertEqual(traces[2]['status'], 'incomplete')

    def test_trace_requires_emitting_process_and_does_not_infer_os_focus(self):
        row = trace('native_request_return', 100)
        self.assertEqual(bench.summarize_traces([row])[0]['status'], 'incomplete')
        del row['processID']
        with self.assertRaises(ValueError):
            bench.summarize_traces([row])

    def test_jsonl_parse_errors_report_line_number(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'samples.jsonl'
            path.write_text('{"kind":"metadata"}\nnot json\n')
            with self.assertRaisesRegex(ValueError, ':2:'):
                list(bench.read_jsonl(path))

    def test_native_log_filter_header_is_allowed_only_for_trace_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.ndjson'
            row = trace('session_received', 100)
            path.write_text('Filtering the log data using "process == test"\n' + json.dumps(row) + '\n')
            self.assertEqual(list(bench.read_jsonl(path, log_stream=True)), [row])
            with self.assertRaises(ValueError):
                list(bench.read_jsonl(path))

    def test_real_observer_protocol_and_exit_without_gui(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'observer.py'
            path.write_text('import sys\nfor line in sys.stdin:\n print(\'{"pid":10,"window_id":2}\', flush=True)\n')
            observer = bench.Observer([sys.executable, str(path)])
            try:
                for _ in range(2):
                    observed = observer.query(bench.time.monotonic_ns() + 2_000_000_000)
                    self.assertEqual(bench.identity(observed), B)
                observer.process.kill()
                observer.process.wait()
                with self.assertRaises((RuntimeError, BrokenPipeError)):
                    observer.query(bench.time.monotonic_ns() + 2_000_000_000)
            finally:
                observer.close()

    def test_collect_and_analyze_cli_without_gui_and_protect_raw_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state.json'
            state.write_text(json.dumps(A))
            observer = root / 'observer'
            observer.write_text(f'#!{sys.executable}\nimport sys\nfrom pathlib import Path\n'
                                f'for line in sys.stdin:\n print(Path({str(state)!r}).read_text(), flush=True)\n')
            observer.chmod(0o755)
            trigger = root / 'trigger.py'
            trigger.write_text('import sys\nfrom pathlib import Path\n'
                               'state = Path(sys.argv[1])\n'
                               'temporary = state.with_suffix(".tmp")\n'
                               'temporary.write_text(sys.argv[2])\n'
                               'temporary.replace(state)\n')
            plan = root / 'plan.json'
            plan.write_text(json.dumps([
                {'expected': target, 'command': [sys.executable, str(trigger), str(state), json.dumps(target)]}
                for target in (B, A)]))
            metadata = root / 'metadata.json'
            metadata.write_text(json.dumps({key: 'synthetic-test' for key in (
                'build', 'revision', 'build_flags', 'signing', 'os', 'hardware', 'apps',
                'window_count', 'displays', 'configuration')}))
            output = root / 'samples.jsonl'
            command = [sys.executable, '-B', str(Path(bench.__file__)), 'collect', '--workload', 'cli-focus',
                       '--observer', str(observer), '--plan', str(plan), '--metadata', str(metadata),
                       '--output', str(output), '--runs', '3', '--warmup', '2', '--iterations', '4']
            subprocess.run(command, check=True, capture_output=True, timeout=20)
            raw = output.read_text()
            analyzed = subprocess.run([sys.executable, '-B', str(Path(bench.__file__)), 'analyze', str(output)],
                                      check=True, capture_output=True, text=True, timeout=5)
            summary = json.loads(analyzed.stdout)
            self.assertTrue(summary['collection_complete'])
            self.assertTrue(summary['at_least_three_runs'])
            self.assertEqual([row['statuses'] for row in summary['runs']], [{'success': 4}] * 3)
            self.assertEqual([row['samples'] for row in summary['warmups']], [2] * 3)
            self.assertEqual(summary['metadata']['metadata']['build'], 'synthetic-test')
            self.assertEqual(len(summary['metadata']['observer_sha256']), 64)
            rejected = subprocess.run(command, capture_output=True, timeout=5)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(output.read_text(), raw)


if __name__ == '__main__':
    unittest.main()
