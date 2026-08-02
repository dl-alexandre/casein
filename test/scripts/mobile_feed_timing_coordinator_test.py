#!/usr/bin/env python3

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from collections import deque
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts/lib"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


collector = load_module(
    "mobile_feed_timing_collector", LIB / "mobile_feed_timing_collector.py"
)
stream = load_module(
    "mobile_feed_timing_stream", LIB / "mobile_feed_timing_stream.py"
)
source = load_module(
    "mobile_feed_timing_source_supervisor",
    LIB / "mobile_feed_timing_source_supervisor.py",
)
coordinator = load_module(
    "mobile_feed_timing_coordinator", LIB / "mobile_feed_timing_coordinator.py"
)


ANDROID_SERIAL = "R52M1234.ADB-1:5555"
IOS_UDID = "00008101-001234560123001E"
IOS_PID = 4242


def raise_keyboard_interrupt(_signum, _frame):
    raise KeyboardInterrupt


@contextlib.contextmanager
def installed_interrupt_handler(signal_value):
    previous = signal.signal(signal_value, raise_keyboard_interrupt)
    try:
        yield
    finally:
        signal.signal(signal_value, previous)


def generation(index: int) -> str:
    return base64.urlsafe_b64encode(index.to_bytes(16, "big")).rstrip(b"=").decode()


def marker(
    generation_value: str,
    stage: str,
    elapsed: int,
    *,
    cycle: str,
) -> bytes:
    outcome = (
        "started"
        if stage in {"app_start", "connect_requested", "tcp_connect_started"}
        else "succeeded"
    )
    reason = "dns_resolved" if stage == "dns_resolved" else "none"
    return (
        "mobile_feed_stage "
        f"connection_generation={generation_value} "
        f"cycle={cycle} stage={stage} duration_ms=1 elapsed_ms={elapsed} "
        f"outcome={outcome} reason_code={reason}\n"
    ).encode("ascii")


def generation_markers(index: int, cycle: str) -> list[bytes]:
    stages = list(collector.REQUIRED_STAGES)
    return [
        marker(generation(index), stage, offset, cycle=cycle)
        for offset, stage in enumerate(stages, 1)
    ]


def summary(value=None):
    return {"min": value, "p50": value, "p95": value, "max": value}


def server_aggregate(*, platform="android", cycle="reconnect", match=True):
    timings = {
        stage: {
            "sample_count": 0,
            "duration_ms": summary(),
            "elapsed_ms": summary(),
        }
        for stage in coordinator.SERVER_STAGES
    }
    timings["token_verified"] = {
        "sample_count": 20,
        "duration_ms": summary(1),
        "elapsed_ms": summary(1),
    }
    outcomes = {value: 0 for value in coordinator.SERVER_OUTCOMES}
    outcomes["succeeded"] = 20
    reasons = {value: 0 for value in coordinator.SERVER_REASONS}
    reasons["none"] = 20
    return {
        "schema_version": 1,
        "component": "server",
        "platform": platform,
        "cycle": cycle,
        "expected_generation_count": 20,
        "observed_generation_count": 20 if match else 19,
        "cohort_match": match,
        "stage_timings": timings,
        "outcome_counts": outcomes,
        "reason_counts": reasons,
        "optional_measurements": {},
    }


class SyntheticSource:
    def __init__(
        self,
        *,
        cycle="reconnect",
        generations=20,
        malformed=False,
        success=True,
        events=None,
        on_start=None,
        processes=(),
    ):
        self.cycle = cycle
        self.generations = generations
        self.malformed = malformed
        self.success = success
        self.events = events
        self.on_start = on_start
        self.processes = tuple(processes)

    def run(self, output, _latch, _vault, registry):
        if self.events is not None:
            self.events.append("source")
        if self.on_start is not None:
            self.on_start()
        for process in self.processes:
            registry.add(process)
        for index in range(1, self.generations + 1):
            lines = generation_markers(index, self.cycle)
            if self.malformed and index == self.generations:
                lines[-1] = b"not-a-marker\n"
            for line in lines:
                output.write(line)
                output.flush()
        return self.success

    def __repr__(self):
        return "SyntheticSource(identity=<redacted>)"


class ClassifiedSyntheticSource(SyntheticSource):
    def __init__(self, *, diagnostic_status, **kwargs):
        super().__init__(**kwargs)
        self._diagnostic_status = diagnostic_status

    def diagnostic_status(self):
        return self._diagnostic_status


class FakeBridge:
    def __init__(
        self,
        aggregate,
        *,
        events=None,
        finish_failure=None,
        waiting_results=None,
        abort_failure=False,
    ):
        self.aggregate = aggregate
        self.events = events
        self.finish_failure = finish_failure
        self.opened = False
        self.aborted = False
        self.finish_calls = 0
        self.payload_length = None
        self.payload_lines = None
        self.payload = None
        self.waiting = True
        self.waiting_results = deque(waiting_results or [])
        self.waiting_calls = 0
        self.abort_failure = abort_failure

    def open(self):
        self.opened = True
        if self.events is not None:
            self.events.append("ready")

    def finish(self, payload):
        self.finish_calls += 1
        self.payload_length = len(payload)
        self.payload_lines = payload.count(b"\n")
        self.payload = payload
        if self.events is not None:
            self.events.append("finish")
        if self.finish_failure is not None:
            raise self.finish_failure
        return self.aggregate

    def assert_waiting(self):
        self.waiting_calls += 1
        if self.waiting_results:
            result = self.waiting_results.popleft()
            if isinstance(result, BaseException):
                raise result
            if not result:
                raise coordinator.CoordinatorFailure("bridge_not_ready")
        if not self.waiting:
            raise coordinator.CoordinatorFailure("bridge_not_ready")

    def abort(self):
        self.aborted = True
        if self.events is not None:
            self.events.append("abort")
        if self.abort_failure:
            raise RuntimeError("fixed")

    def __repr__(self):
        return "FakeBridge(state=<fixed>)"


class FakeCommandRunner:
    def __init__(self):
        self.calls = []

    def run(self, argv, timeout):
        self.calls.append((argv, timeout))


class FakeColdSupervisorFactory:
    def __init__(self):
        self.plans = []
        self.kwargs = []

    def __call__(self, **kwargs):
        self.kwargs.append(kwargs)
        owner = self

        class Supervisor:
            def run(self, plan, _output, status):
                owner.plans.append(plan)
                status.write(
                    json.dumps(
                        {
                            "supervisor": source.SUPERVISOR_NAME,
                            "status": "ios_cold_generation_complete",
                        }
                    )
                    + "\n"
                )
                return 0

        return Supervisor()


class FakeJSONRunnerFactory:
    def __init__(self):
        self.kwargs = []

    def __call__(self, **kwargs):
        self.kwargs.append(kwargs)
        return object()


class FakeIOSContinuousSupervisorFactory:
    def __init__(self, events, *, ready=True):
        self.events = events
        self.ready = ready
        self.plans = []
        self.kwargs = []

    def __call__(self, **kwargs):
        self.kwargs.append(kwargs)
        owner = self

        class Supervisor:
            def run(self, plan, output, status):
                owner.plans.append(plan)
                if plan.ios_launch_mode == "continuous":
                    owner.events.extend(("launch", "attach", "resume"))
                else:
                    owner.events.append("attach")
                if not owner.ready:
                    status.write(
                        json.dumps(
                            {
                                "supervisor": source.SUPERVISOR_NAME,
                                "status": "source_capability_failed",
                            }
                        )
                        + "\n"
                    )
                    return 3

                kwargs["source_ready"]()
                owner.events.append("ready")
                owner.events.append("cold_markers")
                for line in generation_markers(100, "cold"):
                    output.write(line)
                owner.events.append("twenty_reconnect_generations")
                for index in range(1, 21):
                    for line in generation_markers(index, "reconnect"):
                        output.write(line)
                output.flush()
                status.write(
                    json.dumps(
                        {
                            "supervisor": source.SUPERVISOR_NAME,
                            "status": "downstream_complete",
                        }
                    )
                    + "\n"
                )
                return 0

        return Supervisor()


class RecordingLifecycleProcessFactory:
    def __init__(self, events, process=None):
        self.events = events
        self.process = process or FakeWaitProcess([0], pid=711)
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((tuple(argv), kwargs))
        self.events.append("runner")
        return self.process


class FakeWaitProcess:
    def __init__(self, waits, pid=700):
        self.pid = pid
        self.waits = deque(waits)
        self.returncode = None
        self.stdin = None
        self.stdout = None
        self.stderr = None

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        outcome = self.waits.popleft()
        if isinstance(outcome, BaseException):
            raise outcome
        self.returncode = outcome
        return outcome


class FakeProcessGroups:
    def __init__(self, alive=(), term_survivors=(), failures=None, events=None):
        self.alive = set(alive)
        self.term_survivors = set(term_survivors)
        self.failures = dict(failures or {})
        self.events = events
        self.signals = []

    def exists(self, process_group_id):
        return process_group_id in self.alive

    def kill(self, process_group_id, signal_value):
        self.signals.append((process_group_id, signal_value))
        if self.events is not None:
            self.events.append(f"cleanup:{process_group_id}:{signal_value}")
        failure = self.failures.get((process_group_id, signal_value))
        if failure is not None:
            raise failure
        if signal_value == signal.SIGKILL or process_group_id not in self.term_survivors:
            self.alive.discard(process_group_id)


class FakeWriter:
    def __init__(self, *, partial=False, fail=False):
        self.partial = partial
        self.fail = fail
        self.payloads = []
        self.closed = False
        self.flushed = False

    def write(self, payload):
        if self.fail:
            raise BrokenPipeError
        self.payloads.append(payload)
        return len(payload) - 1 if self.partial else len(payload)

    def flush(self):
        self.flushed = True

    def close(self):
        self.closed = True


class FakeFDStream:
    def __init__(self, descriptor):
        self.descriptor = descriptor
        self.closed = False

    def fileno(self):
        return self.descriptor

    def close(self):
        self.closed = True


class FakeBridgeProcess(FakeWaitProcess):
    def __init__(self, waits=(0,), writer=None):
        super().__init__(list(waits))
        self.stdin = writer or FakeWriter()
        self.stdout = FakeFDStream(10)
        self.stderr = FakeFDStream(11)


class FakeSelector:
    def __init__(self, batches):
        self.batches = deque(batches)
        self.registered = {}
        self.closed = False

    def register(self, fileobj, _events, data=None):
        self.registered[fileobj.fileno()] = SimpleNamespace(fileobj=fileobj, data=data)

    def unregister(self, fileobj):
        self.registered.pop(fileobj.fileno(), None)

    def select(self, _timeout=None):
        if not self.batches:
            return []
        descriptors = self.batches.popleft()
        return [(self.registered[descriptor], selectors.EVENT_READ) for descriptor in descriptors]

    def close(self):
        self.closed = True


class SelectorFactory:
    def __init__(self, selectors_):
        self.selectors = deque(selectors_)

    def __call__(self):
        return self.selectors.popleft()


class ReadMap:
    def __init__(self, values):
        self.values = {key: deque(value) for key, value in values.items()}

    def __call__(self, descriptor, _size):
        return self.values[descriptor].popleft()


class FakeMonotonic:
    def __init__(self, values):
        self.values = deque(values)
        self.last = 0.0

    def __call__(self):
        if self.values:
            self.last = self.values.popleft()
        return self.last


class RootFsyncFailurePublisher(coordinator.AtomicAggregatePublisher):
    def _fsync_root(self, _root_fd):
        raise OSError("fixed")


class DeletionFailureAfterRevealPublisher(RootFsyncFailurePublisher):
    def _remove_private_directory(self, *_args):
        raise OSError("fixed")


class InterruptingRootFsyncPublisher(coordinator.AtomicAggregatePublisher):
    def _fsync_root(self, _root_fd):
        raise KeyboardInterrupt


class InterruptAfterPublishPublisher(coordinator.AtomicAggregatePublisher):
    def publish(self, *args, **kwargs):
        super().publish(*args, **kwargs)
        signal.raise_signal(signal.SIGINT)


class InterruptingPinnedOutputRoot(coordinator.PinnedOutputRoot):
    def close(self):
        super().close()
        signal.raise_signal(signal.SIGINT)


class InterruptingOutputRootClosePublisher(coordinator.AtomicAggregatePublisher):
    def preflight(self, output_root):
        pinned = super().preflight(output_root)
        return InterruptingPinnedOutputRoot(pinned.descriptor)


class FailingWritePublisher(coordinator.AtomicAggregatePublisher):
    def _write_one(self, *_args):
        raise OSError("fixed")


class FailAfterAggregateWritesPublisher(coordinator.AtomicAggregatePublisher):
    def __init__(self):
        self.write_count = 0

    def _write_one(self, *args):
        super()._write_one(*args)
        self.write_count += 1
        if self.write_count == 2:
            raise OSError("fixed")


class MobileFeedTimingCoordinatorTest(unittest.TestCase):
    def config(self, root, *, platform="android", cycle="reconnect"):
        if platform == "ios":
            return coordinator.CohortConfig(
                platform=platform,
                cycle=cycle,
                device=IOS_UDID,
                output_root=Path(root),
                ios_pid=IOS_PID if cycle == "reconnect" else None,
            )
        return coordinator.CohortConfig(
            platform=platform,
            cycle=cycle,
            device=ANDROID_SERIAL,
            output_root=Path(root),
        )

    def run_cohort(self, root, bridge, source_driver):
        runner = coordinator.CohortCoordinator(
            bridge_factory=lambda _config: bridge,
            source_factory=lambda _config: source_driver,
        )
        return runner.run(self.config(root))

    def test_ready_precedes_source_and_exact_terminal_payload_is_sent_once(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            bridge = FakeBridge(server_aggregate(), events=events)
            outcome = self.run_cohort(
                root,
                bridge,
                SyntheticSource(events=events),
            )

            self.assertEqual(coordinator.RunOutcome("complete", 0, True), outcome)
            self.assertEqual("ready", events[0])
            self.assertLess(events.index("ready"), events.index("source"))
            self.assertEqual(1, bridge.finish_calls)
            self.assertEqual(460, bridge.payload_length)
            self.assertEqual(20, bridge.payload_lines)
            self.assertEqual(
                [generation(index) for index in range(1, 21)],
                bridge.payload.decode().splitlines(),
            )

    def test_only_terminal_generation_ids_enter_the_vault(self):
        vault = coordinator.TerminalGenerationVault()
        aggregate = collector.Collector("android", "reconnect")
        sink = coordinator.NativeCollectorSink(aggregate, vault)
        adapter = stream.StreamAdapter("android", "reconnect")
        status = coordinator.FixedStatusSink("adapter")

        result = adapter.run(
            io.BytesIO(b"".join(generation_markers(1, "reconnect"))),
            sink,
            status,
        )

        self.assertEqual(2, result)
        self.assertEqual(1, vault.count)
        self.assertNotIn(generation(1), repr(vault))
        self.assertNotIn(generation(1), repr(sink))
        self.assertNotIn(generation(1), repr(aggregate.__dict__))

    def test_partial_pipeline_aborts_fence_and_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            outcome = self.run_cohort(root, bridge, SyntheticSource(generations=19))
            self.assertEqual("pipeline_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_malformed_pipeline_aborts_without_sending(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            outcome = self.run_cohort(
                root, bridge, SyntheticSource(malformed=True)
            )
            self.assertEqual("pipeline_failed", outcome.status)
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_source_failure_after_complete_pipeline_aborts_without_sending(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            outcome = self.run_cohort(
                root, bridge, SyntheticSource(success=False)
            )
            self.assertEqual("source_failed", outcome.status)
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)

    def test_early_source_capability_eof_is_source_failed_with_bounded_diagnostic(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            source_driver = ClassifiedSyntheticSource(
                diagnostic_status="source_capability_failed",
                generations=0,
                success=False,
            )

            outcome = self.run_cohort(root, bridge, source_driver)

            self.assertEqual("source_failed", outcome.status)
            self.assertEqual(
                coordinator.FailureDiagnostic(
                    "native_pipeline",
                    "source_capability_failed",
                    "incomplete",
                    0,
                    0,
                ),
                outcome.diagnostic,
            )
            status_output = io.StringIO()
            coordinator._emit_outcome_status(status_output, outcome)
            emitted = json.loads(status_output.getvalue())
            self.assertEqual(
                {
                    "adapter",
                    "coordinator",
                    "generation_count",
                    "phase",
                    "record_count",
                    "source",
                    "status",
                },
                set(emitted),
            )
            self.assertNotIn(ANDROID_SERIAL, status_output.getvalue())
            self.assertNotIn(generation(1), status_output.getvalue())
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)

    def test_invalid_pipeline_precedes_concurrent_source_failure(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            source_driver = ClassifiedSyntheticSource(
                diagnostic_status="source_capability_failed",
                malformed=True,
                success=False,
            )

            outcome = self.run_cohort(root, bridge, source_driver)

            self.assertEqual("pipeline_failed", outcome.status)
            self.assertIsNotNone(outcome.diagnostic)
            self.assertEqual("invalid", outcome.diagnostic.adapter)
            self.assertEqual(19, outcome.diagnostic.generation_count)
            self.assertLessEqual(
                outcome.diagnostic.record_count,
                coordinator.MAX_AGGREGATE_RECORDS,
            )
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)

    def test_clean_partial_pipeline_from_successful_source_stays_pipeline_failed(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            source_driver = ClassifiedSyntheticSource(
                diagnostic_status="complete",
                generations=19,
                success=True,
            )

            outcome = self.run_cohort(root, bridge, source_driver)

            self.assertEqual("pipeline_failed", outcome.status)
            self.assertEqual("incomplete", outcome.diagnostic.adapter)
            self.assertEqual("complete", outcome.diagnostic.source)
            self.assertEqual(19, outcome.diagnostic.generation_count)

    def test_source_factory_and_abort_failures_still_retire_the_fence(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate(), abort_failure=True)

            def fail_source_factory(_config):
                raise RuntimeError("fixed")

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=fail_source_factory,
            )
            outcome = runner.run(self.config(root))

            self.assertEqual("pipeline_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_interrupt_before_and_during_finish_cleans_up_without_retry(self):
        with tempfile.TemporaryDirectory() as root:
            before_finish = FakeBridge(
                server_aggregate(),
                waiting_results=[True, KeyboardInterrupt()],
            )
            before_outcome = self.run_cohort(
                root, before_finish, SyntheticSource()
            )
            self.assertEqual("interrupted", before_outcome.status)
            self.assertTrue(before_finish.aborted)
            self.assertEqual(0, before_finish.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

            during_finish = FakeBridge(
                server_aggregate(), finish_failure=KeyboardInterrupt()
            )
            during_outcome = self.run_cohort(
                root, during_finish, SyntheticSource()
            )
            self.assertEqual("interrupted", during_outcome.status)
            self.assertTrue(during_finish.aborted)
            self.assertEqual(1, during_finish.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_ambiguous_finish_is_never_retried_or_published(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(
                server_aggregate(),
                finish_failure=coordinator.CoordinatorFailure(
                    "bridge_finish_ambiguous"
                ),
            )
            outcome = self.run_cohort(root, bridge, SyntheticSource())
            self.assertEqual("bridge_finish_ambiguous", outcome.status)
            self.assertEqual(1, bridge.finish_calls)
            self.assertTrue(bridge.aborted)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_bridge_stale_after_ready_aborts_before_send(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            bridge = FakeBridge(server_aggregate(), events=events)
            bridge.waiting = False
            outcome = self.run_cohort(
                root, bridge, SyntheticSource(events=events)
            )
            self.assertEqual("bridge_not_ready", outcome.status)
            self.assertTrue(bridge.aborted)
            self.assertEqual(0, bridge.finish_calls)
            self.assertNotIn("source", events)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_safe_cohort_mismatch_publishes_both_aggregates_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate(match=False))
            outcome = self.run_cohort(root, bridge, SyntheticSource())
            self.assertEqual(coordinator.RunOutcome("cohort_mismatch", 5, True), outcome)
            cohort_dirs = list(Path(root).iterdir())
            self.assertEqual(1, len(cohort_dirs))
            server = json.loads((cohort_dirs[0] / "server.json").read_text())
            self.assertFalse(server["cohort_match"])

    def test_invalid_server_aggregate_is_not_published(self):
        with tempfile.TemporaryDirectory() as root:
            invalid = server_aggregate()
            invalid["connection_generation"] = generation(1)
            bridge = FakeBridge(invalid)
            outcome = self.run_cohort(root, bridge, SyntheticSource())
            self.assertEqual("server_aggregate_invalid", outcome.status)
            self.assertEqual(1, bridge.finish_calls)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_publisher_is_atomic_private_and_contains_only_two_safe_files(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            outcome = self.run_cohort(root, bridge, SyntheticSource())
            self.assertEqual("complete", outcome.status)
            cohort_dirs = list(Path(root).iterdir())
            self.assertEqual(1, len(cohort_dirs))
            cohort = cohort_dirs[0]
            self.assertFalse(cohort.name.startswith("."))
            self.assertEqual(0o700, stat.S_IMODE(cohort.stat().st_mode))
            self.assertEqual(
                {"native.json", "server.json"},
                {path.name for path in cohort.iterdir()},
            )
            for path in cohort.iterdir():
                self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
                self.assertFalse(any(generation(i) in path.read_text() for i in range(1, 21)))

    def test_post_reveal_fsync_and_deletion_failure_truthfully_report_published(self):
        with tempfile.TemporaryDirectory() as root:
            for publisher in (
                RootFsyncFailurePublisher(),
                DeletionFailureAfterRevealPublisher(),
            ):
                with self.subTest(publisher=type(publisher).__name__):
                    run_root = Path(root) / type(publisher).__name__
                    run_root.mkdir()
                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                        source_factory=lambda _config: SyntheticSource(),
                        publisher=publisher,
                    )

                    outcome = runner.run(self.config(run_root))

                    self.assertEqual("complete", outcome.status)
                    self.assertTrue(outcome.published)
                    cohort_dirs = list(run_root.iterdir())
                    self.assertEqual(1, len(cohort_dirs))
                    self.assertEqual(
                        {"native.json", "server.json"},
                        {path.name for path in cohort_dirs[0].iterdir()},
                    )

    def test_interrupt_after_reveal_truthfully_reports_visible_publication(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=InterruptingRootFsyncPublisher(),
            )

            outcome = runner.run(self.config(root))

            self.assertEqual("complete", outcome.status)
            self.assertTrue(outcome.published)
            cohort_dirs = list(Path(root).iterdir())
            self.assertEqual(1, len(cohort_dirs))
            self.assertEqual(
                {"native.json", "server.json"},
                {path.name for path in cohort_dirs[0].iterdir()},
            )

    def test_signal_after_mkdir_is_deferred_until_staging_can_be_removed(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                with tempfile.TemporaryDirectory() as root:
                    real_mkdir = os.mkdir

                    def mkdir_then_signal(*args, **kwargs):
                        real_mkdir(*args, **kwargs)
                        signal.raise_signal(interrupt_signal)

                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                        source_factory=lambda _config: SyntheticSource(),
                    )

                    with (
                        installed_interrupt_handler(interrupt_signal),
                        mock.patch.object(
                            coordinator.os, "mkdir", mkdir_then_signal
                        ),
                    ):
                        outcome = runner.run(self.config(root))

                    self.assertEqual("interrupted", outcome.status)
                    self.assertFalse(outcome.published)
                    self.assertEqual([], list(Path(root).iterdir()))

    def test_signal_after_replace_is_deferred_until_receipt_is_committed(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                with tempfile.TemporaryDirectory() as root:
                    real_replace = os.replace

                    def replace_then_signal(*args, **kwargs):
                        real_replace(*args, **kwargs)
                        signal.raise_signal(interrupt_signal)

                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                        source_factory=lambda _config: SyntheticSource(),
                    )

                    with (
                        installed_interrupt_handler(interrupt_signal),
                        mock.patch.object(
                            coordinator.os, "replace", replace_then_signal
                        ),
                    ):
                        outcome = runner.run(self.config(root))

                    self.assert_published_aggregate(root, outcome)

    def test_post_publish_signal_uses_shared_committed_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=InterruptAfterPublishPublisher(),
            )

            with installed_interrupt_handler(signal.SIGINT):
                outcome = runner.run(self.config(root))

            self.assert_published_aggregate(root, outcome)

    def test_post_publish_signal_preserves_committed_mismatch_status(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(
                    server_aggregate(match=False)
                ),
                source_factory=lambda _config: SyntheticSource(),
                publisher=InterruptAfterPublishPublisher(),
            )

            with installed_interrupt_handler(signal.SIGINT):
                outcome = runner.run(self.config(root))

            self.assertEqual(coordinator.RunOutcome("cohort_mismatch", 5, True), outcome)
            self.assertEqual(1, len(list(Path(root).iterdir())))

    def test_output_root_close_signal_uses_shared_committed_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=InterruptingOutputRootClosePublisher(),
            )

            with installed_interrupt_handler(signal.SIGINT):
                outcome = runner.run(self.config(root))

            self.assert_published_aggregate(root, outcome)

    def test_staging_close_signal_preserves_committed_publication(self):
        with tempfile.TemporaryDirectory() as root:
            real_close = os.close
            signaled = False

            def close_then_signal(descriptor):
                nonlocal signaled
                is_directory = stat.S_ISDIR(os.fstat(descriptor).st_mode)
                real_close(descriptor)
                if is_directory and not signaled:
                    signaled = True
                    signal.raise_signal(signal.SIGINT)

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )

            with (
                installed_interrupt_handler(signal.SIGINT),
                mock.patch.object(coordinator.os, "close", close_then_signal),
            ):
                outcome = runner.run(self.config(root))

            self.assertTrue(signaled)
            self.assert_published_aggregate(root, outcome)

    def test_staging_fsync_signal_removes_uncommitted_artifact(self):
        with tempfile.TemporaryDirectory() as root:
            real_fsync = os.fsync
            signaled = False

            def fsync_then_signal(descriptor):
                nonlocal signaled
                is_directory = stat.S_ISDIR(os.fstat(descriptor).st_mode)
                real_fsync(descriptor)
                if is_directory and not signaled:
                    signaled = True
                    signal.raise_signal(signal.SIGINT)

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )

            with (
                installed_interrupt_handler(signal.SIGINT),
                mock.patch.object(coordinator.os, "fsync", fsync_then_signal),
            ):
                outcome = runner.run(self.config(root))

            self.assertTrue(signaled)
            self.assertEqual("interrupted", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_cleanup_signal_is_deferred_until_staging_is_removed(self):
        with tempfile.TemporaryDirectory() as root:
            real_rmdir = os.rmdir

            def rmdir_then_signal(*args, **kwargs):
                real_rmdir(*args, **kwargs)
                signal.raise_signal(signal.SIGINT)

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=FailingWritePublisher(),
            )

            with (
                installed_interrupt_handler(signal.SIGINT),
                mock.patch.object(coordinator.os, "rmdir", rmdir_then_signal),
            ):
                outcome = runner.run(self.config(root))

            self.assertEqual("interrupted", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_transient_cleanup_unlink_failure_is_retried_without_a_leak(self):
        with tempfile.TemporaryDirectory() as root:
            real_unlink = os.unlink
            failed_once = False

            def unlink_fail_once(*args, **kwargs):
                nonlocal failed_once
                if not failed_once:
                    failed_once = True
                    raise OSError("fixed")
                return real_unlink(*args, **kwargs)

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=FailAfterAggregateWritesPublisher(),
            )

            with mock.patch.object(coordinator.os, "unlink", unlink_fail_once):
                outcome = runner.run(self.config(root))

            self.assertTrue(failed_once)
            self.assertEqual(
                coordinator.RunOutcome("publication_failed", 4, False), outcome
            )
            self.assertEqual([], list(Path(root).iterdir()))

    def test_transient_cleanup_open_and_rmdir_failures_are_bounded_and_retried(self):
        with tempfile.TemporaryDirectory() as root:
            real_open = os.open
            real_rmdir = os.rmdir
            cleanup_started = False
            cleanup_open_failed = False

            def rmdir_fail_once(*args, **kwargs):
                nonlocal cleanup_started
                if not cleanup_started:
                    cleanup_started = True
                    raise OSError("fixed")
                return real_rmdir(*args, **kwargs)

            def cleanup_open_fail_once(path, *args, **kwargs):
                nonlocal cleanup_open_failed
                if (
                    cleanup_started
                    and not cleanup_open_failed
                    and isinstance(path, str)
                    and path.startswith(".casein-mobile-feed-timing-")
                ):
                    cleanup_open_failed = True
                    raise OSError("fixed")
                return real_open(path, *args, **kwargs)

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=FailingWritePublisher(),
            )

            with (
                mock.patch.object(coordinator.os, "open", cleanup_open_fail_once),
                mock.patch.object(coordinator.os, "rmdir", rmdir_fail_once),
            ):
                outcome = runner.run(self.config(root))

            self.assertTrue(cleanup_started)
            self.assertTrue(cleanup_open_failed)
            self.assertEqual(
                coordinator.RunOutcome("publication_failed", 4, False), outcome
            )
            self.assertEqual([], list(Path(root).iterdir()))

    def test_persistent_cleanup_refusal_is_bounded_and_never_attested(self):
        with tempfile.TemporaryDirectory() as root:
            rmdir_calls = 0

            def refuse_rmdir(*_args, **_kwargs):
                nonlocal rmdir_calls
                rmdir_calls += 1
                raise OSError("fixed")

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
                publisher=FailingWritePublisher(),
            )

            with mock.patch.object(coordinator.os, "rmdir", refuse_rmdir):
                outcome = runner.run(self.config(root))

            self.assertEqual(coordinator.PUBLICATION_CLEANUP_ATTEMPTS, rmdir_calls)
            self.assertEqual(
                coordinator.RunOutcome("publication_failed", 4, False), outcome
            )
            remaining = list(Path(root).iterdir())
            self.assertEqual(1, len(remaining))
            self.assertTrue(remaining[0].name.startswith("."))
            self.assertEqual(0o700, stat.S_IMODE(remaining[0].stat().st_mode))

    def test_failed_replace_removes_staging_and_never_commits_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )

            with mock.patch.object(
                coordinator.os, "replace", side_effect=OSError("fixed")
            ):
                outcome = runner.run(self.config(root))

            self.assertEqual("publication_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual([], list(Path(root).iterdir()))

    def assert_published_aggregate(self, root, outcome):
        self.assertEqual("complete", outcome.status)
        self.assertTrue(outcome.published)
        cohort_dirs = list(Path(root).iterdir())
        self.assertEqual(1, len(cohort_dirs))
        self.assertFalse(cohort_dirs[0].name.startswith("."))
        self.assertEqual(0o700, stat.S_IMODE(cohort_dirs[0].stat().st_mode))
        self.assertEqual(
            {"native.json", "server.json"},
            {path.name for path in cohort_dirs[0].iterdir()},
        )
        for path in cohort_dirs[0].iterdir():
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    def test_main_run_boundary_uses_shared_committed_receipt(self):
        class InterruptAfterRunCoordinator(coordinator.CohortCoordinator):
            def run(self, config, receipt=None):
                outcome = super().run(config, receipt)
                signal.raise_signal(signal.SIGINT)
                return outcome

        with tempfile.TemporaryDirectory() as root:
            stderr = io.StringIO()
            runner = InterruptAfterRunCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )
            argv = [
                "--platform",
                "android",
                "--cycle",
                "reconnect",
                "--device",
                ANDROID_SERIAL,
                "--output-root",
                root,
            ]

            with (
                installed_interrupt_handler(signal.SIGINT),
                mock.patch.object(coordinator, "CohortCoordinator", return_value=runner),
                mock.patch.object(coordinator.sys, "stderr", stderr),
            ):
                exit_code = coordinator.main(argv)

            self.assertEqual(0, exit_code)
            self.assertEqual(
                {"coordinator": coordinator.COORDINATOR_NAME, "status": "complete"},
                json.loads(stderr.getvalue()),
            )
            self.assertEqual(1, len(list(Path(root).iterdir())))

    def test_main_emits_committed_status_across_signal_boundary(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            for matched, expected_status, expected_exit in (
                (True, "complete", 0),
                (False, "cohort_mismatch", 5),
            ):
                with self.subTest(
                    signal=interrupt_signal,
                    status=expected_status,
                ):
                    with tempfile.TemporaryDirectory() as root:
                        stderr = io.StringIO()
                        signaled = False
                        runner = coordinator.CohortCoordinator(
                            bridge_factory=lambda _config: FakeBridge(
                                server_aggregate(match=matched)
                            ),
                            source_factory=lambda _config: SyntheticSource(),
                        )
                        real_fixed_status = coordinator._fixed_status

                        def signal_then_write(output, status, diagnostic=None):
                            nonlocal signaled
                            if not signaled:
                                signaled = True
                                signal.raise_signal(interrupt_signal)
                            real_fixed_status(output, status, diagnostic)

                        argv = [
                            "--platform",
                            "android",
                            "--cycle",
                            "reconnect",
                            "--device",
                            ANDROID_SERIAL,
                            "--output-root",
                            root,
                        ]

                        with (
                            mock.patch.object(
                                coordinator,
                                "CohortCoordinator",
                                return_value=runner,
                            ),
                            mock.patch.object(
                                coordinator,
                                "_fixed_status",
                                signal_then_write,
                            ),
                            mock.patch.object(coordinator.sys, "stderr", stderr),
                        ):
                            exit_code = coordinator.main(argv)

                        self.assertTrue(signaled)
                        self.assertEqual(expected_exit, exit_code)
                        self.assertEqual(
                            {
                                "coordinator": coordinator.COORDINATOR_NAME,
                                "status": expected_status,
                            },
                            json.loads(stderr.getvalue()),
                        )
                        self.assertEqual(1, len(list(Path(root).iterdir())))

    def test_main_ignores_committed_signal_after_status_write(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                with tempfile.TemporaryDirectory() as root:
                    stderr = io.StringIO()
                    signaled = False
                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                        source_factory=lambda _config: SyntheticSource(),
                    )
                    real_fixed_status = coordinator._fixed_status

                    def write_then_signal(output, status, diagnostic=None):
                        nonlocal signaled
                        real_fixed_status(output, status, diagnostic)
                        if not signaled:
                            signaled = True
                            signal.raise_signal(interrupt_signal)

                    argv = [
                        "--platform",
                        "android",
                        "--cycle",
                        "reconnect",
                        "--device",
                        ANDROID_SERIAL,
                        "--output-root",
                        root,
                    ]

                    with (
                        mock.patch.object(
                            coordinator,
                            "CohortCoordinator",
                            return_value=runner,
                        ),
                        mock.patch.object(
                            coordinator,
                            "_fixed_status",
                            write_then_signal,
                        ),
                        mock.patch.object(coordinator.sys, "stderr", stderr),
                    ):
                        exit_code = coordinator.main(argv)

                    self.assertTrue(signaled)
                    self.assertEqual(0, exit_code)
                    self.assertEqual(
                        {
                            "coordinator": coordinator.COORDINATOR_NAME,
                            "status": "complete",
                        },
                        json.loads(stderr.getvalue()),
                    )
                    self.assertEqual(1, len(list(Path(root).iterdir())))

    def test_main_precommit_signal_still_emits_interrupted_status_once(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                with tempfile.TemporaryDirectory() as root:
                    stderr = io.StringIO()
                    signaled = False
                    real_fixed_status = coordinator._fixed_status

                    def signal_then_write(output, status, diagnostic=None):
                        nonlocal signaled
                        if not signaled:
                            signaled = True
                            signal.raise_signal(interrupt_signal)
                        real_fixed_status(output, status, diagnostic)

                    argv = [
                        "--platform",
                        "android",
                        "--cycle",
                        "reconnect",
                        "--device",
                        ANDROID_SERIAL,
                        "--output-root",
                        str(Path(root) / "missing"),
                    ]

                    with (
                        mock.patch.object(
                            coordinator,
                            "_fixed_status",
                            signal_then_write,
                        ),
                        mock.patch.object(coordinator.sys, "stderr", stderr),
                    ):
                        exit_code = coordinator.main(argv)

                    self.assertTrue(signaled)
                    self.assertEqual(
                        coordinator.EXIT_CODES["interrupted"], exit_code
                    )
                    self.assertEqual(
                        {
                            "adapter": "not_started",
                            "coordinator": coordinator.COORDINATOR_NAME,
                            "generation_count": 0,
                            "phase": "initialization",
                            "record_count": 0,
                            "source": "not_started",
                            "status": "interrupted",
                        },
                        json.loads(stderr.getvalue()),
                    )

    def test_cli_keeps_receipt_handlers_through_post_return_exit_boundary(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                with tempfile.TemporaryDirectory() as root:
                    stderr = io.StringIO()
                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                        source_factory=lambda _config: SyntheticSource(),
                    )
                    argv = [
                        "--platform",
                        "android",
                        "--cycle",
                        "reconnect",
                        "--device",
                        ANDROID_SERIAL,
                        "--output-root",
                        root,
                    ]
                    previous_handlers = {
                        value: signal.getsignal(value)
                        for value in (signal.SIGINT, signal.SIGTERM)
                    }

                    try:
                        with (
                            mock.patch.object(
                                coordinator,
                                "CohortCoordinator",
                                return_value=runner,
                            ),
                            mock.patch.object(coordinator.sys, "stderr", stderr),
                        ):
                            exit_code = coordinator._cli_main(argv)

                        signal.raise_signal(interrupt_signal)
                        self.assertEqual(0, exit_code)
                        self.assertEqual(
                            {
                                "coordinator": coordinator.COORDINATOR_NAME,
                                "status": "complete",
                            },
                            json.loads(stderr.getvalue()),
                        )
                    finally:
                        for value, previous_handler in previous_handlers.items():
                            signal.signal(value, previous_handler)

    def test_library_main_restores_both_signal_handlers(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )
            argv = [
                "--platform",
                "android",
                "--cycle",
                "reconnect",
                "--device",
                ANDROID_SERIAL,
                "--output-root",
                root,
            ]
            previous_handlers = {
                value: signal.getsignal(value)
                for value in (signal.SIGINT, signal.SIGTERM)
            }

            with (
                mock.patch.object(
                    coordinator,
                    "CohortCoordinator",
                    return_value=runner,
                ),
                mock.patch.object(coordinator.sys, "stderr", io.StringIO()),
            ):
                exit_code = coordinator.main(argv)

            self.assertEqual(0, exit_code)
            for value, previous_handler in previous_handlers.items():
                self.assertEqual(previous_handler, signal.getsignal(value))

    def test_signal_during_handler_installation_is_deferred_and_bounded(self):
        for pending_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=pending_signal):
                with tempfile.TemporaryDirectory() as root:
                    stderr = io.StringIO()
                    bridge = FakeBridge(server_aggregate())
                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: bridge,
                        source_factory=lambda _config: SyntheticSource(),
                    )
                    argv = [
                        "--platform",
                        "android",
                        "--cycle",
                        "reconnect",
                        "--device",
                        ANDROID_SERIAL,
                        "--output-root",
                        root,
                    ]
                    real_signal = signal.signal
                    queued = False

                    def install_then_queue(signum, handler):
                        nonlocal queued
                        previous = real_signal(signum, handler)
                        if (
                            not queued
                            and signum == signal.SIGINT
                            and callable(handler)
                        ):
                            queued = True
                            signal.raise_signal(pending_signal)
                        return previous

                    with (
                        mock.patch.object(
                            coordinator,
                            "CohortCoordinator",
                            return_value=runner,
                        ),
                        mock.patch.object(
                            coordinator.signal,
                            "signal",
                            install_then_queue,
                        ),
                        mock.patch.object(coordinator.sys, "stderr", stderr),
                    ):
                        exit_code = coordinator.main(argv)

                    self.assertTrue(queued)
                    self.assertEqual(
                        coordinator.EXIT_CODES["interrupted"], exit_code
                    )
                    self.assertEqual(
                        {
                            "adapter": "not_started",
                            "coordinator": coordinator.COORDINATOR_NAME,
                            "generation_count": 0,
                            "phase": "initialization",
                            "record_count": 0,
                            "source": "not_started",
                            "status": "interrupted",
                        },
                        json.loads(stderr.getvalue()),
                    )
                    self.assertFalse(bridge.opened)

    def test_signal_during_library_restoration_restores_every_handler(self):
        with tempfile.TemporaryDirectory() as root:
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )
            argv = [
                "--platform",
                "android",
                "--cycle",
                "reconnect",
                "--device",
                ANDROID_SERIAL,
                "--output-root",
                root,
            ]
            previous_handlers = {
                value: signal.getsignal(value)
                for value in (signal.SIGINT, signal.SIGTERM)
            }
            real_signal = signal.signal
            queued = False

            def restore_then_queue(signum, handler):
                nonlocal queued
                previous = real_signal(signum, handler)
                if (
                    not queued
                    and signum == signal.SIGINT
                    and handler == previous_handlers[signal.SIGINT]
                ):
                    queued = True
                    signal.raise_signal(signal.SIGINT)
                return previous

            with (
                mock.patch.object(
                    coordinator,
                    "CohortCoordinator",
                    return_value=runner,
                ),
                mock.patch.object(
                    coordinator.signal,
                    "signal",
                    restore_then_queue,
                ),
                mock.patch.object(coordinator.sys, "stderr", io.StringIO()),
            ):
                exit_code = coordinator.main(argv)

            self.assertTrue(queued)
            self.assertEqual(0, exit_code)
            for value, previous_handler in previous_handlers.items():
                self.assertEqual(previous_handler, signal.getsignal(value))

    def test_committed_receipt_cannot_override_a_second_failed_run(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = coordinator.PublicationReceipt()
            first_root = Path(root) / "first"
            first_root.mkdir()
            first_runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(),
            )

            first_outcome = first_runner.run(self.config(first_root), receipt)

            second_bridge = FakeBridge(server_aggregate())
            second_runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: second_bridge,
                source_factory=lambda _config: SyntheticSource(),
            )
            second_config = self.config(Path(root) / "missing")
            second_outcome = second_runner.run(second_config, receipt)

            self.assertEqual(coordinator.RunOutcome("complete", 0, True), first_outcome)
            self.assertEqual(
                coordinator.RunOutcome("internal_error", 70, False), second_outcome
            )
            self.assertFalse(second_bridge.opened)

    def test_prepared_and_claimed_receipts_cannot_start_a_run(self):
        for state in ("claimed", "prepared"):
            with self.subTest(state=state):
                with tempfile.TemporaryDirectory() as root:
                    receipt = coordinator.PublicationReceipt()
                    self.assertTrue(receipt.claim())
                    if state == "prepared":
                        receipt.prepare("complete")
                    bridge = FakeBridge(server_aggregate())
                    runner = coordinator.CohortCoordinator(
                        bridge_factory=lambda _config: bridge,
                        source_factory=lambda _config: SyntheticSource(),
                    )

                    outcome = runner.run(self.config(root), receipt)

                    self.assertEqual(
                        coordinator.RunOutcome("internal_error", 70, False), outcome
                    )
                    self.assertFalse(bridge.opened)
                    self.assertEqual([], list(Path(root).iterdir()))

    def test_pinned_output_root_cannot_be_redirected_after_preflight(self):
        with tempfile.TemporaryDirectory() as parent:
            output_root = Path(parent) / "output"
            moved_root = Path(parent) / "pinned"
            output_root.mkdir()

            def replace_output_path():
                output_root.rename(moved_root)
                output_root.mkdir()

            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(server_aggregate()),
                source_factory=lambda _config: SyntheticSource(
                    on_start=replace_output_path
                ),
            )

            outcome = runner.run(self.config(output_root))

            self.assertEqual("complete", outcome.status)
            self.assertTrue(outcome.published)
            self.assertEqual([], list(output_root.iterdir()))
            cohort_dirs = list(moved_root.iterdir())
            self.assertEqual(1, len(cohort_dirs))
            self.assertEqual(
                {"native.json", "server.json"},
                {path.name for path in cohort_dirs[0].iterdir()},
            )

    def test_output_root_symlink_is_rejected_before_bridge_or_source(self):
        with tempfile.TemporaryDirectory() as root:
            actual = Path(root) / "actual"
            actual.mkdir()
            linked = Path(root) / "linked"
            linked.symlink_to(actual, target_is_directory=True)
            events = []
            bridge = FakeBridge(server_aggregate(), events=events)
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(events=events),
            )

            outcome = runner.run(self.config(linked))

            self.assertEqual("publication_failed", outcome.status)
            self.assertFalse(bridge.opened)
            self.assertNotIn("source", events)
            self.assertEqual([], list(actual.iterdir()))

    def test_generation_ids_are_absent_from_repr_fixed_status_and_files(self):
        with tempfile.TemporaryDirectory() as root:
            bridge = FakeBridge(server_aggregate())
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(),
            )
            config = self.config(root)
            outcome = runner.run(config)
            status = io.StringIO()
            coordinator._fixed_status(status, outcome.status)
            text = repr(runner) + repr(config) + repr(bridge) + status.getvalue()
            files = b"".join(path.read_bytes() for path in Path(root).rglob("*.json"))
            for index in range(1, 21):
                raw = generation(index)
                self.assertNotIn(raw, text)
                self.assertNotIn(raw.encode(), files)

    def test_completion_latch_distinguishes_pipeline_and_cohort_states(self):
        latch = coordinator.CompletionLatch()
        self.assertEqual("pending", latch.pipeline_state)
        self.assertEqual("pending", latch.cohort_state)
        self.assertIsNone(latch.downstream_status())
        latch.mark_pipeline_complete()
        self.assertEqual(0, latch.downstream_status())
        self.assertEqual("pending", latch.cohort_state)
        latch.mark_cohort(matched=False)
        self.assertEqual("complete", latch.pipeline_state)
        self.assertEqual("mismatched", latch.cohort_state)

    def test_completion_latch_failure_never_looks_complete(self):
        latch = coordinator.CompletionLatch()
        latch.mark_pipeline_failed()
        self.assertFalse(latch.wait_pipeline(0))
        self.assertIsNone(latch.downstream_status())
        latch.mark_cohort(matched=None)
        self.assertEqual("failed", latch.cohort_state)

    def test_android_cold_lifecycle_is_exact_package_only_force_stop_start_order(self):
        with tempfile.TemporaryDirectory() as root:
            config = self.config(root, cycle="cold")
            driver = coordinator.PhysicalSourceDriver(config)
            runner = FakeCommandRunner()
            vault = coordinator.TerminalGenerationVault()
            for index in range(1, 21):
                vault.add_terminal(generation(index))
            driver._run_android_cold(runner, vault)
            self.assertEqual(40, len(runner.calls))
            for offset in range(0, 40, 2):
                self.assertEqual(
                    coordinator.build_android_force_stop_argv(ANDROID_SERIAL),
                    runner.calls[offset][0],
                )
                self.assertEqual(
                    coordinator.build_android_start_argv(ANDROID_SERIAL),
                    runner.calls[offset + 1][0],
                )
            joined = repr([call[0] for call in runner.calls])
            self.assertNotIn("pm clear", joined)
            self.assertNotIn("uninstall", joined)

    def test_android_cold_concurrent_source_ready_precedes_every_lifecycle_command(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            source_can_finish = threading.Event()
            commands_complete = threading.Event()
            latch = coordinator.CompletionLatch()
            vault = coordinator.TerminalGenerationVault()
            result = {}

            class ExitedSourceProcess:
                pid = 741
                stdin = None
                stdout = None
                stderr = None

                def poll(self):
                    return 0

                def wait(self, timeout=None):
                    return 0

            def source_process_factory(_argv, **_kwargs):
                events.append("source_process_created")
                return ExitedSourceProcess()

            class ConcurrentSupervisor:
                def __init__(self, **kwargs):
                    self.process_factory = kwargs["process_factory"]
                    self.line_reader_factory = kwargs["line_reader_factory"]
                    self.downstream_status = kwargs["downstream_status"]

                def run(self, plan, _output, status):
                    self.process_factory(
                        plan.source_argv,
                        shell=False,
                        start_new_session=True,
                    )
                    read_fd, write_fd = os.pipe()
                    read_stream = os.fdopen(read_fd, "rb", buffering=0)
                    reader = None
                    try:
                        reader = self.line_reader_factory(read_stream)
                        events.append("source_ready")
                        self.assert_downstream_pending()
                        if not source_can_finish.wait(2):
                            raise AssertionError("source completion was not released")
                        if self.downstream_status() != 0:
                            raise AssertionError("pipeline completion was not visible")
                        status.write(
                            json.dumps(
                                {
                                    "supervisor": source.SUPERVISOR_NAME,
                                    "status": "downstream_complete",
                                }
                            )
                            + "\n"
                        )
                        return 0
                    finally:
                        if reader is not None:
                            reader.close()
                        read_stream.close()
                        os.close(write_fd)

                def assert_downstream_pending(self):
                    if self.downstream_status() is not None:
                        raise AssertionError("pipeline completed before lifecycle")

            class ConcurrentCommandRunner:
                def __init__(self, _factory):
                    self.starts = 0

                def run(self, argv, _timeout):
                    if argv == coordinator.build_android_force_stop_argv(
                        ANDROID_SERIAL
                    ):
                        events.append("force_stop")
                        return
                    if argv == coordinator.build_android_start_argv(ANDROID_SERIAL):
                        self.starts += 1
                        events.append("start")
                        vault.add_terminal(generation(self.starts))
                        if self.starts == coordinator.TARGET_GENERATIONS:
                            commands_complete.set()
                        return
                    raise AssertionError("unexpected lifecycle command")

            driver = coordinator.PhysicalSourceDriver(
                self.config(root, cycle="cold"),
                process_factory=source_process_factory,
                supervisor_factory=ConcurrentSupervisor,
            )
            registry = coordinator.ScopedProcessRegistry(
                kill_process_group=lambda _pid, _signal: None
            )

            def run_driver():
                result["success"] = driver.run(
                    io.BytesIO(), latch, vault, registry
                )

            with mock.patch.object(
                coordinator,
                "BoundedCommandRunner",
                ConcurrentCommandRunner,
            ):
                worker = threading.Thread(target=run_driver)
                worker.start()
                self.assertTrue(commands_complete.wait(2))
                self.assertEqual("source_process_created", events[0])
                self.assertEqual("source_ready", events[1])
                self.assertEqual(
                    ["force_stop", "start"] * coordinator.TARGET_GENERATIONS,
                    events[2:],
                )
                latch.mark_pipeline_complete()
                source_can_finish.set()
                worker.join(2)

            self.assertFalse(worker.is_alive())
            self.assertTrue(result["success"])
            self.assertEqual("downstream_complete", driver.diagnostic_status())

    def test_android_cold_source_capability_failure_never_starts_lifecycle(self):
        with tempfile.TemporaryDirectory() as root:
            for capability in ("missing_stdout", "invalid_reader"):
                with self.subTest(capability=capability):
                    command_runner_created = False
                    stream = None if capability == "missing_stdout" else io.BytesIO()

                    class IncapableSourceProcess:
                        pid = 752
                        stdin = None
                        stdout = stream
                        stderr = None

                        def poll(self):
                            return 0

                        def wait(self, timeout=None):
                            return 0

                    def process_factory(_argv, **_kwargs):
                        return IncapableSourceProcess()

                    class ForbiddenCommandRunner:
                        def __init__(self, _factory):
                            nonlocal command_runner_created
                            command_runner_created = True

                    driver = coordinator.PhysicalSourceDriver(
                        self.config(root, cycle="cold"),
                        process_factory=process_factory,
                    )
                    registry = coordinator.ScopedProcessRegistry()

                    with (
                        mock.patch.object(
                            coordinator,
                            "SOURCE_READY_TIMEOUT_SECONDS",
                            0,
                        ),
                        mock.patch.object(
                            coordinator,
                            "BoundedCommandRunner",
                            ForbiddenCommandRunner,
                        ),
                    ):
                        success = driver.run(
                            io.BytesIO(),
                            coordinator.CompletionLatch(),
                            coordinator.TerminalGenerationVault(),
                            registry,
                        )

                    self.assertFalse(success)
                    self.assertFalse(command_runner_created)
                    self.assertEqual(
                        "source_capability_failed", driver.diagnostic_status()
                    )
                    if stream is not None:
                        stream.close()

    def test_android_reconnect_runner_is_exact_serial_and_one_test_method(self):
        argv = coordinator.build_android_reconnect_runner_argv(ANDROID_SERIAL)
        self.assertEqual("adb", argv[0])
        self.assertEqual(("-s", ANDROID_SERIAL), argv[2:4])
        self.assertIn("instrument", argv)
        self.assertEqual(coordinator.ANDROID_RECONNECT_TEST, argv[-2])
        self.assertEqual(coordinator.ANDROID_TEST_RUNNER, argv[-1])
        self.assertNotIn("connectedAndroidTest", argv)

    def test_ios_cold_plan_is_start_stopped_and_reconnect_runner_is_exact(self):
        plan = source.build_plan("ios", IOS_UDID, ios_suspended_launch=True)
        self.assertEqual("cold_once", plan.ios_launch_mode)
        self.assertIsNone(plan.ios_pid)
        launch = source.build_ios_launch_suspended_argv(IOS_UDID)
        self.assertIn("--start-stopped", launch)
        self.assertIn("--terminate-existing", launch)

        argv = coordinator.build_ios_reconnect_runner_argv(IOS_UDID)
        self.assertEqual(
            ROOT / "native/casein_mob/ios/run_feed_lifecycle_soak.sh",
            Path(argv[0]),
        )
        self.assertEqual(IOS_UDID, argv[1])
        self.assertEqual(2, len(argv))

    def test_ios_cold_coordinator_runs_exactly_twenty_sequential_cold_once_plans(self):
        with tempfile.TemporaryDirectory() as root:
            supervisors = FakeColdSupervisorFactory()
            json_runners = FakeJSONRunnerFactory()
            driver = coordinator.PhysicalSourceDriver(
                self.config(root, platform="ios", cycle="cold"),
                supervisor_factory=supervisors,
                json_runner_factory=json_runners,
            )
            registry = coordinator.ScopedProcessRegistry(
                kill_process_group=lambda _pid, _signal: None
            )

            self.assertTrue(driver._run_ios_cold(io.BytesIO(), registry))
            self.assertEqual(20, len(supervisors.plans))
            self.assertTrue(
                all(plan.ios_launch_mode == "cold_once" for plan in supervisors.plans)
            )
            self.assertTrue(all(plan.device_id == IOS_UDID for plan in supervisors.plans))
            self.assertEqual(1, len(json_runners.kwargs))

    def test_ios_reconnect_without_external_pid_uses_one_ready_continuous_source(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            supervisors = FakeIOSContinuousSupervisorFactory(events)
            processes = RecordingLifecycleProcessFactory(events)
            bridge = FakeBridge(
                server_aggregate(platform="ios", cycle="reconnect")
            )
            config = coordinator.CohortConfig(
                platform="ios",
                cycle="reconnect",
                device=IOS_UDID,
                output_root=Path(root),
            )
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda source_config: coordinator.PhysicalSourceDriver(
                    source_config,
                    process_factory=processes,
                    supervisor_factory=supervisors,
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=lambda _pid, _signal: None,
                    process_group_exists=lambda _pid: False,
                ),
            )

            outcome = runner.run(config)

            self.assertEqual(coordinator.RunOutcome("complete", 0, True), outcome)
            self.assertEqual(1, len(supervisors.plans))
            plan = supervisors.plans[0]
            self.assertEqual("continuous", plan.ios_launch_mode)
            self.assertIsNone(plan.ios_pid)
            self.assertEqual((), plan.source_argv)
            self.assertLess(events.index("resume"), events.index("ready"))
            self.assertLess(events.index("ready"), events.index("runner"))
            self.assertLess(
                events.index("cold_markers"),
                events.index("twenty_reconnect_generations"),
            )
            self.assertEqual(1, len(processes.calls))
            self.assertEqual(
                coordinator.build_ios_reconnect_runner_argv(IOS_UDID),
                processes.calls[0][0],
            )
            command_text = " ".join(processes.calls[0][0])
            for forbidden in ("pgrep", "pidof", "process list", "ps "):
                self.assertNotIn(forbidden, command_text)

    def test_ios_reconnect_explicit_pid_remains_exact_running_attach(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            supervisors = FakeIOSContinuousSupervisorFactory(events)
            processes = RecordingLifecycleProcessFactory(events)
            config = coordinator.CohortConfig(
                platform="ios",
                cycle="reconnect",
                device=IOS_UDID,
                output_root=Path(root),
                ios_pid=IOS_PID,
            )
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: FakeBridge(
                    server_aggregate(platform="ios", cycle="reconnect")
                ),
                source_factory=lambda source_config: coordinator.PhysicalSourceDriver(
                    source_config,
                    process_factory=processes,
                    supervisor_factory=supervisors,
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=lambda _pid, _signal: None,
                    process_group_exists=lambda _pid: False,
                ),
            )

            outcome = runner.run(config)

            self.assertEqual("complete", outcome.status)
            self.assertEqual(IOS_PID, supervisors.plans[0].ios_pid)
            self.assertIsNone(supervisors.plans[0].ios_launch_mode)
            self.assertCountEqual(
                [
                    "attach",
                    "ready",
                    "cold_markers",
                    "twenty_reconnect_generations",
                    "runner",
                ],
                events,
            )
            self.assertLess(events.index("attach"), events.index("ready"))
            self.assertLess(events.index("ready"), events.index("runner"))
            self.assertLess(
                events.index("ready"), events.index("cold_markers")
            )
            self.assertLess(
                events.index("cold_markers"),
                events.index("twenty_reconnect_generations"),
            )

    def test_ios_resume_failure_starts_zero_lifecycle_runners(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            supervisors = FakeIOSContinuousSupervisorFactory(
                events, ready=False
            )
            processes = RecordingLifecycleProcessFactory(events)
            config = coordinator.CohortConfig(
                platform="ios",
                cycle="reconnect",
                device=IOS_UDID,
                output_root=Path(root),
            )
            driver = coordinator.PhysicalSourceDriver(
                config,
                process_factory=processes,
                supervisor_factory=supervisors,
            )
            registry = coordinator.ScopedProcessRegistry(
                kill_process_group=lambda _pid, _signal: None,
                process_group_exists=lambda _pid: False,
            )

            with mock.patch.object(
                coordinator, "SOURCE_READY_TIMEOUT_SECONDS", 0
            ):
                result = driver._run_continuous(
                    io.BytesIO(),
                    coordinator.CompletionLatch(),
                    coordinator.TerminalGenerationVault(),
                    registry,
                )

            self.assertFalse(result)
            self.assertEqual([], processes.calls)
            self.assertNotIn("runner", events)

    def test_ios_continuous_cleanup_failure_prevents_publication(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            process = FakeWaitProcess([0], pid=712)
            groups = FakeProcessGroups(alive=(process.pid,))
            supervisors = FakeIOSContinuousSupervisorFactory(events)
            processes = RecordingLifecycleProcessFactory(events, process)
            bridge = FakeBridge(
                server_aggregate(platform="ios", cycle="reconnect")
            )
            config = coordinator.CohortConfig(
                platform="ios",
                cycle="reconnect",
                device=IOS_UDID,
                output_root=Path(root),
            )
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda source_config: coordinator.PhysicalSourceDriver(
                    source_config,
                    process_factory=processes,
                    supervisor_factory=supervisors,
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=groups.kill,
                    process_group_exists=groups.exists,
                ),
            )

            outcome = runner.run(config)

            self.assertEqual("source_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual(0, bridge.finish_calls)
            self.assertTrue(bridge.aborted)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_ios_pid_inputs_fail_closed_and_duplicate_cli_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            invalid_pids = (
                True,
                False,
                0,
                -1,
                source.MAX_PID + 1,
                "42",
                1.5,
            )
            for pid in invalid_pids:
                with self.subTest(pid=repr(pid)):
                    with self.assertRaises(coordinator.InvalidArguments):
                        coordinator.CohortConfig(
                            platform="ios",
                            cycle="reconnect",
                            device=IOS_UDID,
                            output_root=Path(root),
                            ios_pid=pid,
                        )

            base = [
                "--platform",
                "ios",
                "--cycle",
                "reconnect",
                "--device",
                IOS_UDID,
                "--output-root",
                root,
            ]
            for malformed in ("true", "0", str(source.MAX_PID + 1)):
                with self.subTest(malformed=malformed):
                    with self.assertRaises(
                        (coordinator.InvalidArguments, source.SourceFailure)
                    ):
                        args = coordinator._parser().parse_args(
                            base + ["--ios-pid", malformed]
                        )
                        coordinator.CohortConfig(
                            platform=args.platform,
                            cycle=args.cycle,
                            device=args.device,
                            output_root=args.output_root,
                            ios_pid=args.ios_pid,
                        )

            with self.assertRaises(coordinator.InvalidArguments):
                coordinator._parser().parse_args(
                    base
                    + [
                        "--ios-pid",
                        str(IOS_PID),
                        f"--ios-pid={IOS_PID}",
                    ]
                )

    def test_no_platform_or_device_defaults_or_origin_switch_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(coordinator.InvalidArguments):
                coordinator.CohortConfig(
                    platform="android",
                    cycle="origin_switch",
                    device=ANDROID_SERIAL,
                    output_root=Path(root),
                )
            ios_reconnect = coordinator.CohortConfig(
                platform="ios",
                cycle="reconnect",
                device=IOS_UDID,
                output_root=Path(root),
            )
            self.assertIsNone(ios_reconnect.ios_pid)
            with self.assertRaises(coordinator.InvalidArguments):
                coordinator.CohortConfig(
                    platform="android",
                    cycle="cold",
                    device="",
                    output_root=Path(root),
                )

    def test_fixed_bridge_argv_has_no_shell_or_supplied_host(self):
        argv = coordinator.build_bridge_argv("android", "cold")
        self.assertEqual("ssh", argv[0])
        self.assertEqual(coordinator.BRIDGE_SSH_HOST, argv[-5])
        self.assertEqual("--", argv[-4])
        self.assertEqual(coordinator.BRIDGE_RELEASE_HELPER, argv[-3])
        self.assertEqual("cold", argv[-1])
        self.assertNotIn("sh", argv)
        self.assertNotIn("bash", argv)

    def test_bridge_rejects_malformed_stdout_before_ready(self):
        process = FakeBridgeProcess()
        selector = FakeSelector([[10]])
        reads = ReadMap({10: [b"stale\n"], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: selector,
            read_fn=reads,
        )
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.open()
        self.assertEqual("bridge_not_ready", failure.exception.status)
        self.assertTrue(process.stdin.closed)

    def test_bridge_rejects_partial_ready_and_closes_stdin(self):
        process = FakeBridgeProcess()
        selector = FakeSelector([[10], []])
        reads = ReadMap({10: [coordinator.BRIDGE_READY[:-1]], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: selector,
            read_fn=reads,
        )
        with self.assertRaises(coordinator.CoordinatorFailure):
            session.open()
        self.assertTrue(process.stdin.closed)

    def test_bridge_rejects_no_ready_frame(self):
        process = FakeBridgeProcess()
        selector = FakeSelector([[10]])
        reads = ReadMap({10: [b""], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: selector,
            read_fn=reads,
        )
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.open()
        self.assertEqual("bridge_not_ready", failure.exception.status)
        self.assertTrue(process.stdin.closed)

    def test_bridge_rejects_extra_line_coalesced_with_ready(self):
        process = FakeBridgeProcess()
        selector = FakeSelector([[10]])
        reads = ReadMap({10: [coordinator.BRIDGE_READY + b"extra\n"], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: selector,
            read_fn=reads,
        )
        with self.assertRaises(coordinator.CoordinatorFailure):
            session.open()
        self.assertTrue(process.stdin.closed)

    def test_bridge_rejects_stderr_racing_exact_ready(self):
        process = FakeBridgeProcess()
        selector = FakeSelector([[10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY],
                11: [coordinator.BRIDGE_FAILED],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: selector,
            read_fn=reads,
        )
        with self.assertRaises(coordinator.CoordinatorFailure):
            session.open()
        self.assertTrue(process.stdin.closed)

    def test_bridge_exact_ready_then_one_exact_send_and_fixed_aggregate(self):
        aggregate = json.dumps(server_aggregate(), separators=(",", ":")).encode() + b"\n"
        process = FakeBridgeProcess(waits=(0,))
        handshake = FakeSelector([[10]])
        waiting = FakeSelector([[]])
        finish = FakeSelector([[10], [10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, aggregate, b""],
                11: [b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, waiting, finish]),
            read_fn=reads,
        )
        session.open()
        session.assert_waiting()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        result = session.finish(payload)
        self.assertTrue(result["cohort_match"])
        self.assertEqual([payload], process.stdin.payloads)
        self.assertTrue(process.stdin.closed)
        with self.assertRaises(coordinator.CoordinatorFailure):
            session.finish(payload)
        self.assertEqual([payload], process.stdin.payloads)

    def test_bridge_rejects_early_final_frame_before_send(self):
        aggregate = json.dumps(server_aggregate(), separators=(",", ":")).encode() + b"\n"
        process = FakeBridgeProcess()
        handshake = FakeSelector([[10]])
        waiting = FakeSelector([[10]])
        reads = ReadMap({10: [coordinator.BRIDGE_READY, aggregate], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, waiting]),
            read_fn=reads,
        )
        session.open()
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.assert_waiting()
        self.assertEqual("bridge_not_ready", failure.exception.status)

    def test_bridge_rejects_missing_final_frame(self):
        process = FakeBridgeProcess(waits=(0,))
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10], [11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, b""],
                11: [b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_rejects_extra_final_line(self):
        aggregate = json.dumps(server_aggregate(), separators=(",", ":")).encode()
        process = FakeBridgeProcess(waits=(0,))
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10], [10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, aggregate + b"\nextra\n", b""],
                11: [b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_rejects_malformed_final_json(self):
        process = FakeBridgeProcess(waits=(0,))
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10], [10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, b"{malformed}\n", b""],
                11: [b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("server_aggregate_invalid", failure.exception.status)

    def test_bridge_rejects_final_phase_stderr(self):
        aggregate = json.dumps(server_aggregate(), separators=(",", ":")).encode() + b"\n"
        process = FakeBridgeProcess(waits=(0,))
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10, 11], [10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, aggregate, b""],
                11: [coordinator.BRIDGE_FAILED, b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_rejects_nonzero_exit_after_valid_final_frame(self):
        aggregate = json.dumps(server_aggregate(), separators=(",", ":")).encode() + b"\n"
        process = FakeBridgeProcess(waits=(74,))
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10], [10, 11]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, aggregate, b""],
                11: [b""],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_rejects_finish_timeout(self):
        process = FakeBridgeProcess(
            waits=(subprocess.TimeoutExpired("fixed", 0),)
        )
        handshake = FakeSelector([[10]])
        finish = FakeSelector([])
        reads = ReadMap({10: [coordinator.BRIDGE_READY], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
            monotonic=FakeMonotonic([0, 0, 0, 16, 16]),
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_rejects_oversized_final_frame(self):
        oversized = b"{" + b"x" * coordinator.MAX_BRIDGE_AGGREGATE_WIRE_BYTES + b"}\n"
        process = FakeBridgeProcess()
        handshake = FakeSelector([[10]])
        finish = FakeSelector([[10]])
        reads = ReadMap(
            {
                10: [coordinator.BRIDGE_READY, oversized],
                11: [],
            }
        )
        session = coordinator.BridgeSession(
            "android",
            "reconnect",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=SelectorFactory([handshake, finish]),
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)

    def test_bridge_payload_validator_rejects_duplicate_cr_and_wrong_size(self):
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        self.assertTrue(coordinator._generation_payload_valid(payload))
        duplicate = b"".join(f"{generation(1)}\n".encode() for _ in range(20))
        self.assertFalse(coordinator._generation_payload_valid(duplicate))
        self.assertFalse(coordinator._generation_payload_valid(payload.replace(b"\n", b"\r\n")))
        self.assertFalse(coordinator._generation_payload_valid(payload[:-1]))

    def test_bridge_final_frame_requires_exact_json_object_envelope(self):
        valid = b'{"component":"server"}\n'
        self.assertEqual(
            b'{"component":"server"}',
            coordinator._strict_bridge_final_payload(valid),
        )

        invalid = (
            b" " + valid,
            valid[:-1] + b" \n",
            valid[:-1] + b"\r\n",
            valid[:-2] + b"\x00}\n",
            valid + b"extra\n",
            valid[:-1],
            b"[]\n",
            b"{}\n\n",
        )
        for frame in invalid:
            with self.subTest(frame=frame):
                self.assertIsNone(coordinator._strict_bridge_final_payload(frame))

    def test_partial_bridge_write_is_ambiguous_and_never_retried(self):
        process = FakeBridgeProcess(writer=FakeWriter(partial=True))
        handshake = FakeSelector([[10]])
        reads = ReadMap({10: [coordinator.BRIDGE_READY], 11: []})
        session = coordinator.BridgeSession(
            "android",
            "cold",
            process_factory=lambda *_args, **_kwargs: process,
            selector_factory=lambda: handshake,
            read_fn=reads,
        )
        session.open()
        payload = b"".join(f"{generation(i)}\n".encode() for i in range(1, 21))
        with self.assertRaises(coordinator.CoordinatorFailure) as failure:
            session.finish(payload)
        self.assertEqual("bridge_finish_ambiguous", failure.exception.status)
        self.assertEqual([payload], process.stdin.payloads)

    def test_scoped_cleanup_escalates_term_then_kill(self):
        process = FakeWaitProcess([subprocess.TimeoutExpired("fixed", 1), 0])
        groups = FakeProcessGroups(
            alive=(process.pid,), term_survivors=(process.pid,)
        )
        result = coordinator._terminate_process_group(
            process, groups.kill, groups.exists
        )
        self.assertEqual("killed", result)
        self.assertEqual(
            [(process.pid, signal.SIGTERM), (process.pid, signal.SIGKILL)],
            groups.signals,
        )

    def test_scoped_cleanup_refuses_reused_group_after_leader_exit(self):
        process = FakeWaitProcess([], pid=703)
        process.returncode = 0
        groups = FakeProcessGroups(alive=(process.pid,))

        result = coordinator._terminate_process_group(
            process, groups.kill, groups.exists
        )

        self.assertEqual("failed", result)
        self.assertEqual([], groups.signals)
        self.assertTrue(groups.exists(process.pid))

    def test_scoped_cleanup_does_not_escalate_after_leader_exits(self):
        process = FakeWaitProcess([0], pid=708)
        groups = FakeProcessGroups(
            alive=(process.pid,), term_survivors=(process.pid,)
        )

        result = coordinator._terminate_process_group(
            process, groups.kill, groups.exists
        )

        self.assertEqual("failed", result)
        self.assertEqual([(process.pid, signal.SIGTERM)], groups.signals)
        self.assertTrue(groups.exists(process.pid))

    def test_registry_cleanup_does_not_short_circuit_after_a_failed_child(self):
        first = FakeWaitProcess(
            [
                subprocess.TimeoutExpired("fixed", 1),
                subprocess.TimeoutExpired("fixed", 1),
            ],
            pid=701,
        )
        second = FakeWaitProcess([0], pid=702)
        groups = FakeProcessGroups(
            alive=(first.pid, second.pid), term_survivors=(first.pid,)
        )
        registry = coordinator.ScopedProcessRegistry(
            kill_process_group=groups.kill,
            process_group_exists=groups.exists,
        )
        registry.add(first)
        registry.add(second)

        self.assertFalse(registry.terminate_all())
        self.assertEqual(
            [
                (701, signal.SIGTERM),
                (701, signal.SIGKILL),
                (702, signal.SIGTERM),
            ],
            groups.signals,
        )

    def test_registry_defers_base_exception_until_every_child_was_visited(self):
        first = FakeWaitProcess([0], pid=704)
        second = FakeWaitProcess([0], pid=705)
        groups = FakeProcessGroups(
            alive=(first.pid, second.pid),
            failures={(first.pid, signal.SIGTERM): KeyboardInterrupt()},
        )
        registry = coordinator.ScopedProcessRegistry(
            kill_process_group=groups.kill,
            process_group_exists=groups.exists,
        )
        registry.add(first)
        registry.add(second)

        with self.assertRaises(KeyboardInterrupt):
            registry.terminate_all()

        self.assertEqual(
            [
                (first.pid, signal.SIGTERM),
                (second.pid, signal.SIGTERM),
            ],
            groups.signals,
        )
        self.assertFalse(groups.exists(second.pid))

    def test_native_process_groups_are_authoritatively_cleaned_before_bridge_send(self):
        with tempfile.TemporaryDirectory() as root:
            events = []
            process = FakeWaitProcess([0], pid=706)
            groups = FakeProcessGroups(alive=(process.pid,), events=events)
            bridge = FakeBridge(server_aggregate(), events=events)
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(
                    events=events, processes=(process,)
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=groups.kill,
                    process_group_exists=groups.exists,
                ),
            )

            outcome = runner.run(self.config(root))

            self.assertEqual("complete", outcome.status)
            cleanup_event = f"cleanup:{process.pid}:{signal.SIGTERM}"
            self.assertLess(events.index(cleanup_event), events.index("finish"))
            self.assertEqual(1, bridge.finish_calls)

    def test_native_cleanup_failure_prevents_bridge_send_and_publication(self):
        with tempfile.TemporaryDirectory() as root:
            process = FakeWaitProcess(
                [
                    subprocess.TimeoutExpired("fixed", 1),
                    subprocess.TimeoutExpired("fixed", 1),
                ],
                pid=707,
            )
            groups = FakeProcessGroups(
                alive=(process.pid,), term_survivors=(process.pid,)
            )
            bridge = FakeBridge(server_aggregate())
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(
                    processes=(process,)
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=groups.kill,
                    process_group_exists=groups.exists,
                ),
            )

            outcome = runner.run(self.config(root))

            self.assertEqual("source_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual(0, bridge.finish_calls)
            self.assertTrue(bridge.aborted)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_reused_group_after_leader_exit_is_never_signalled_or_published(self):
        with tempfile.TemporaryDirectory() as root:
            process = FakeWaitProcess([], pid=709)
            process.returncode = 0
            groups = FakeProcessGroups(alive=(process.pid,))
            bridge = FakeBridge(server_aggregate())
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(
                    processes=(process,)
                ),
                registry_factory=lambda: coordinator.ScopedProcessRegistry(
                    kill_process_group=groups.kill,
                    process_group_exists=groups.exists,
                ),
            )

            outcome = runner.run(self.config(root))

            self.assertEqual("source_failed", outcome.status)
            self.assertFalse(outcome.published)
            self.assertEqual([], groups.signals)
            self.assertEqual(0, bridge.finish_calls)
            self.assertTrue(bridge.aborted)
            self.assertEqual([], list(Path(root).iterdir()))

    def test_only_bridge_child_environment_inherits_ssh_agent_socket(self):
        with mock.patch.dict(
            os.environ,
            {
                "PATH": "/fixed/bin",
                "SSH_AUTH_SOCK": "/private/fixed-agent.sock",
                "UNRELATED_SECRET": "never-inherit",
            },
            clear=True,
        ):
            native = coordinator._safe_native_child_env()
            bridge = coordinator._safe_bridge_child_env()

        self.assertNotIn("SSH_AUTH_SOCK", native)
        self.assertEqual("/private/fixed-agent.sock", bridge["SSH_AUTH_SOCK"])
        self.assertNotIn("UNRELATED_SECRET", native)
        self.assertNotIn("UNRELATED_SECRET", bridge)

    def test_server_validator_rejects_wrong_fixed_shape_and_nonfinite_values(self):
        invalid = server_aggregate()
        invalid["stage_timings"]["token_verified"]["duration_ms"]["max"] = float("inf")
        with self.assertRaises(coordinator.CoordinatorFailure):
            coordinator.validate_server_aggregate(invalid, "android", "reconnect")
        invalid = server_aggregate()
        del invalid["reason_counts"]["none"]
        with self.assertRaises(coordinator.CoordinatorFailure):
            coordinator.validate_server_aggregate(invalid, "android", "reconnect")

    def test_server_validator_mirrors_summary_and_cross_map_invariants(self):
        invalid_cases = []

        occupied_null = server_aggregate()
        occupied_null["stage_timings"]["token_verified"]["duration_ms"] = summary()
        invalid_cases.append(occupied_null)

        short_p95 = server_aggregate()
        short_p95["stage_timings"]["token_verified"] = {
            "sample_count": 1,
            "duration_ms": summary(1),
            "elapsed_ms": summary(1),
        }
        short_p95["outcome_counts"]["succeeded"] = 1
        short_p95["reason_counts"]["none"] = 1
        short_p95["cohort_match"] = False
        invalid_cases.append(short_p95)

        unordered = server_aggregate()
        unordered["stage_timings"]["token_verified"]["elapsed_ms"] = {
            "min": 4,
            "p50": 3,
            "p95": 2,
            "max": 1,
        }
        invalid_cases.append(unordered)

        cross_map = server_aggregate()
        cross_map["reason_counts"]["none"] = 19
        invalid_cases.append(cross_map)

        optional_excess = server_aggregate()
        optional_excess["optional_measurements"]["card_count"] = {
            "sample_count": 21,
            "min": 1,
            "p50": 1,
            "p95": 1,
            "max": 1,
        }
        invalid_cases.append(optional_excess)

        positive_without_observation = server_aggregate(match=False)
        positive_without_observation["observed_generation_count"] = 0
        invalid_cases.append(positive_without_observation)

        for index, aggregate in enumerate(invalid_cases):
            with self.subTest(case=index):
                with self.assertRaises(coordinator.CoordinatorFailure):
                    coordinator.validate_server_aggregate(
                        aggregate, "android", "reconnect"
                    )

        empty_mismatch = server_aggregate(match=False)
        empty_mismatch["observed_generation_count"] = 0
        empty_mismatch["stage_timings"]["token_verified"] = {
            "sample_count": 0,
            "duration_ms": summary(),
            "elapsed_ms": summary(),
        }
        empty_mismatch["outcome_counts"]["succeeded"] = 0
        empty_mismatch["reason_counts"]["none"] = 0
        self.assertFalse(
            coordinator.validate_server_aggregate(
                empty_mismatch, "android", "reconnect"
            )["cohort_match"]
        )

    def test_fixed_status_never_reflects_unknown_or_identity(self):
        output = io.StringIO()
        coordinator._fixed_status(output, generation(1))
        self.assertEqual(
            {
                "adapter": "not_started",
                "coordinator": coordinator.COORDINATOR_NAME,
                "generation_count": 0,
                "phase": "initialization",
                "record_count": 0,
                "source": "not_started",
                "status": "internal_error",
            },
            json.loads(output.getvalue()),
        )
        self.assertNotIn(generation(1), output.getvalue())

        sink = coordinator.FixedStatusSink("adapter")
        with self.assertRaises(ValueError):
            sink.write(
                json.dumps(
                    {
                        "adapter": stream.ADAPTER_NAME,
                        "status": f"complete-{generation(1)}",
                    }
                )
                + "\n"
            )
        self.assertNotIn(generation(1), repr(sink))

        supervisor_sink = coordinator.FixedStatusSink("supervisor")
        with self.assertRaises(ValueError):
            supervisor_sink.write(
                json.dumps(
                    {
                        "supervisor": source.SUPERVISOR_NAME,
                        "status": "source_capability_failed",
                        "unexpected": generation(1),
                    }
                )
                + "\n"
            )
        self.assertIsNone(supervisor_sink.status)
        self.assertNotIn(generation(1), repr(supervisor_sink))

    def test_fixed_status_keeps_success_two_fields_and_failure_allowlisted(self):
        diagnostic = coordinator.FailureDiagnostic(
            "native_pipeline",
            "source_capability_failed",
            "incomplete",
            7,
            1,
        )
        success = io.StringIO()
        failure = io.StringIO()

        coordinator._fixed_status(success, "complete", diagnostic)
        coordinator._fixed_status(failure, "source_failed", diagnostic)

        self.assertEqual(
            {"coordinator": coordinator.COORDINATOR_NAME, "status": "complete"},
            json.loads(success.getvalue()),
        )
        self.assertEqual(
            {
                "coordinator": coordinator.COORDINATOR_NAME,
                "status": "source_failed",
                "phase": "native_pipeline",
                "source": "source_capability_failed",
                "adapter": "incomplete",
                "record_count": 7,
                "generation_count": 1,
            },
            json.loads(failure.getvalue()),
        )
        with self.assertRaises(ValueError):
            coordinator.FailureDiagnostic(
                generation(1), "failed", "invalid", 0, 0
            )
        with self.assertRaises(ValueError):
            coordinator.FailureDiagnostic(
                "native_pipeline", "failed", "invalid", 2_001, 0
            )

    def test_invalid_output_root_fails_before_bridge_or_source(self):
        with tempfile.TemporaryDirectory() as root:
            missing = Path(root) / "missing"
            bridge = FakeBridge(server_aggregate())
            runner = coordinator.CohortCoordinator(
                bridge_factory=lambda _config: bridge,
                source_factory=lambda _config: SyntheticSource(),
            )
            outcome = runner.run(
                coordinator.CohortConfig(
                    platform="android",
                    cycle="reconnect",
                    device=ANDROID_SERIAL,
                    output_root=missing,
                )
            )
            self.assertEqual("publication_failed", outcome.status)
            self.assertFalse(bridge.opened)
            self.assertEqual(0, bridge.finish_calls)

    def test_main_failure_output_is_fixed_identity_free_diagnostic(self):
        with tempfile.TemporaryDirectory() as root:
            missing = Path(root) / "missing"
            stderr = io.StringIO()
            argv = [
                "--platform",
                "android",
                "--cycle",
                "reconnect",
                "--device",
                ANDROID_SERIAL,
                "--output-root",
                os.fspath(missing),
            ]

            with mock.patch.object(coordinator.sys, "stderr", stderr):
                exit_code = coordinator.main(argv)

            self.assertEqual(coordinator.EXIT_CODES["publication_failed"], exit_code)
            self.assertEqual(
                {
                    "adapter": "not_started",
                    "coordinator": coordinator.COORDINATOR_NAME,
                    "generation_count": 0,
                    "phase": "publication_preflight",
                    "record_count": 0,
                    "source": "not_started",
                    "status": "publication_failed",
                },
                json.loads(stderr.getvalue()),
            )
            self.assertNotIn(ANDROID_SERIAL, stderr.getvalue())

    def test_disable_artifacts_sets_bytecode_and_zero_core_limit(self):
        coordinator.disable_process_artifacts()
        self.assertTrue(sys.dont_write_bytecode)
        self.assertEqual((0, 0), coordinator.resource.getrlimit(coordinator.resource.RLIMIT_CORE))

    def test_signal_handler_converts_once_to_bounded_interruption(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                receipt = coordinator.PublicationReceipt()
                with mock.patch.object(coordinator.signal, "signal") as set_signal:
                    with self.assertRaises(KeyboardInterrupt):
                        coordinator._interrupt_on_signal(
                            receipt, interrupt_signal, None
                        )
                set_signal.assert_called_once_with(
                    interrupt_signal, signal.SIG_IGN
                )

    def test_signal_handler_ignores_after_publication_commit(self):
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interrupt_signal):
                receipt = coordinator.PublicationReceipt()
                self.assertTrue(receipt.claim())
                receipt.prepare("complete")
                receipt.commit()

                with mock.patch.object(coordinator.signal, "signal") as set_signal:
                    coordinator._interrupt_on_signal(
                        receipt, interrupt_signal, None
                    )

                set_signal.assert_called_once_with(
                    interrupt_signal, signal.SIG_IGN
                )


if __name__ == "__main__":
    unittest.main()
