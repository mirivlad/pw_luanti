"""One run, start to finish, including every way it can end badly.

The order below is not arbitrary. Each step depends on the one before it, and
the teardown runs in reverse whatever happened:

    pick a free display
    -> start Xvfb or Xephyr on it
    -> launch a real Luanti client
    -> find its window and prove the window is that process
    -> focus the window inside its own display
    -> wait for the bridge to say the player is connected
    -> wait for the brain to say it is thinking
    -> claim intents and execute them until told to stop
    -> release every key
    -> stop the client
    -> stop the display
    -> write the report

**Releasing keys comes before everything else in teardown, on every path.** A
crash while holding W leaves a client walking into a wall forever; there is no
error important enough to be worth reporting while that is happening.
"""

from __future__ import annotations

import json
import os
import signal
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from .bridge_client import BridgeClient
from .config import Config
from .display import make_display
from .errors import (BridgeRefused, BridgeUnavailable, ClientError, DependencyMissing,
                     DisplayError, IntentInvalid, OperatorStopped, RuntimeError_,
                     WindowNotFound)
from .executor import IntentExecutor
from .input_backend import make_backend
from .intent_client import IntentClient
from .interaction import InteractionController
from .movement import MovementController
from .process import LuantiClient, screenshot
from .reporting import RunArtifacts, build_result, new_run_id, prune_old_runs


class ControlState:
    """Pause, resume and stop, shared between the run and its control file.

    The operator's commands arrive as small files in the run directory rather
    than as signals, so ``pw-bot-runtime pause`` works from any terminal and
    does not need to know a process id.
    """

    def __init__(self, directory: Path) -> None:
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self._paused = threading.Event()
        self._stopped = threading.Event()
        self.stop_reason = ""

    @property
    def control_path(self) -> Path:
        return self.directory / "control.json"

    def poll(self) -> None:
        """Read any command the operator left, then consume it."""
        path = self.control_path
        if not path.exists():
            return
        try:
            command = json.loads(path.read_text(encoding="utf-8")).get("command", "")
        except (json.JSONDecodeError, OSError):
            command = ""
        finally:
            try:
                path.unlink()
            except OSError:
                pass
        if command == "pause":
            self._paused.set()
        elif command == "resume":
            self._paused.clear()
        elif command == "stop":
            self.stop_reason = "operator requested stop"
            self._stopped.set()

    def send(self, command: str) -> None:
        temporary = self.directory / ".control.json.tmp"
        temporary.write_text(json.dumps({"command": command}), encoding="utf-8")
        os.replace(temporary, self.control_path)

    @property
    def paused(self) -> bool:
        return self._paused.is_set()

    @property
    def stopped(self) -> bool:
        return self._stopped.is_set()

    def stop(self, reason: str = "stopped") -> None:
        self.stop_reason = reason
        self._stopped.set()

    def should_continue(self) -> bool:
        """False when the run must not take another physical action."""
        return not self._stopped.is_set() and not self._paused.is_set()


class BotRun:
    """A single supervised run of a real client driven by real intents."""

    def __init__(self, config: Config, *, visible: bool | None = None,
                 keep_open: bool | None = None, run_id: str | None = None,
                 max_intents: int = 0, max_seconds: float = 0.0) -> None:
        self.config = config
        if visible is not None:
            config.display.mode = "visible" if visible else "headless"
        if keep_open is not None:
            config.client.keep_open_after_run = keep_open
        self.run_id = run_id or new_run_id()
        self.max_intents = max_intents
        self.max_seconds = max_seconds

        self.artifacts = RunArtifacts(config.artifacts_path, self.run_id)
        self.log = self.artifacts.logger
        self.control = ControlState(self.artifacts.directory)

        self.display = None
        self.client: LuantiClient | None = None
        self.input = None
        self.bridge: BridgeClient | None = None
        self.intents: IntentClient | None = None
        self.movement: MovementController | None = None
        self.interaction: InteractionController | None = None
        self.executor: IntentExecutor | None = None

        self.timeline: list[dict] = []
        self.intent_log: list[dict] = []
        self.started = 0.0
        self.status = "unknown"
        self.ok = False
        self.reason = ""
        self._keys_released = False

    # --- bookkeeping ----------------------------------------------------------

    def event(self, message: str, **extra) -> None:
        entry = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                 "event": message, **extra}
        self.timeline.append(entry)
        self.log.info(message)

    def _record_control(self, action: str, **extra) -> None:
        self.artifacts.append("controls", {"action": action, **extra})

    # --- setup -----------------------------------------------------------------

    def _start_display(self) -> None:
        self.display = make_display(
            mode=self.config.display.mode,
            backend=self.config.display.visible_backend,
            width=self.config.client.width,
            height=self.config.client.height,
            allow_host=self.config.display.allow_host_display_fallback,
            position=(self.config.display.window_position_x,
                      self.config.display.window_position_y),
            search=(self.config.display.display_search_start,
                    self.config.display.display_search_end))
        display = self.display.start()
        self.event(f"display {display} up ({self.display.name})")
        self.artifacts.write_json("display.json", self.display.describe())

    def _start_client(self) -> None:
        self.client = LuantiClient(self.config, self.display.display, self.artifacts.client_log)
        self.client.start()
        self.event(f"launched a real Luanti client, pid {self.client.process.pid}")
        window = self.client.find_window(timeout=self.config.client.startup_timeout_seconds)
        self.event(f"window {window} verified as belonging to the client process")
        self.client.focus_window()
        description = self.client.describe()
        self.artifacts.write_json("display.json",
                                  {**self.display.describe(), "client": description})

    def _start_input(self) -> None:
        self.input = make_backend(self.config.input.backend, self.display.display,
                                  self.client.window_id if self.client else None)
        self.event(f"input backend: {self.input.name}")

    def _connect_bridge(self) -> None:
        self.bridge = BridgeClient(
            self.config.bridge_spool, self.config.server.player_name,
            self.config.bridge.poll_interval_ms, self.config.bridge.request_timeout_ms,
            logger=self.log)
        ready, detail = self.bridge.is_ready()
        if not ready:
            raise BridgeUnavailable(detail)
        state = self.bridge.wait_for_player(timeout=self.config.client.startup_timeout_seconds)
        self.event(f"{self.config.server.player_name} is connected and observable at "
                   f"({state.x:.1f}, {state.y:.1f}, {state.z:.1f})")
        self.artifacts.append("bridge-observations",
                              {"phase": "connected", "state": state.raw})

    def _connect_brain(self) -> None:
        self.intents = IntentClient(
            self.config.brain_spool, self.config.server.player_name,
            state_dir=self.artifacts.directory, logger=self.log)
        ready, detail = self.intents.is_ready()
        if not ready:
            raise RuntimeError_(detail)
        deadline = time.time() + self.config.client.startup_timeout_seconds
        while time.time() < deadline:
            state = self.intents.brain_state()
            if state.get("thinking"):
                self.event(f"the brain is thinking (tick {state.get('ticks', 0)}, "
                           f"{state.get('memory_cells', 0)} remembered columns)")
                return
            time.sleep(0.5)
        self.event("the brain never reported that it was thinking; continuing anyway")

    def _build_controllers(self) -> None:
        self.movement = MovementController(
            self.input, self.bridge, self.config.movement, logger=self.log,
            should_continue=self.control.should_continue)
        if self.config.movement.calibrate_yaw_on_start:
            calibration = self.movement.calibrate_yaw()
            self.event(f"yaw calibration: {calibration['radians_per_pixel']:.6f} rad/px "
                       f"({calibration['source']})")
            self._record_control("calibrate_yaw", **calibration)
        self.interaction = InteractionController(self.input, self.bridge, self.movement,
                                                 logger=self.log)
        self.executor = IntentExecutor(self.input, self.bridge, self.movement,
                                       self.interaction, self.config, logger=self.log,
                                       should_continue=self.control.should_continue)

    # --- the loop ----------------------------------------------------------------

    def _loop(self) -> None:
        executed = 0
        idle_since = time.monotonic()
        backoff = self.config.brain.think_interval_ms / 1000.0

        while True:
            self.control.poll()
            if self.control.stopped:
                self.status, self.ok = "operator_stopped", False
                self.reason = self.control.stop_reason or "operator stopped the run"
                return

            if self.control.paused:
                # Pausing must not leave a key down: the body stops, the intent
                # is kept, and nothing about the run is lost.
                released = self.input.release_all()
                if released:
                    self._record_control("release_all", keys=released, cause="pause")
                time.sleep(0.3)
                continue

            if self.max_seconds and time.monotonic() - self.started > self.max_seconds:
                self.status, self.ok = "reached", True
                self.reason = f"ran for the requested {self.max_seconds:.0f}s"
                return

            if self.client and not self.client.is_alive():
                self.status, self.ok = "client_disconnected", False
                self.reason = "the Luanti client exited"
                return

            if self.display and not self.display.is_alive():
                self.status, self.ok = "operator_stopped", False
                self.reason = "the display went away (the window was probably closed)"
                return

            try:
                intent = self.intents.claim()
            except IntentInvalid as exc:
                self.log.warning("refused an intent: %s", exc)
                self.artifacts.append("intents", {"refused": exc.as_dict()})
                time.sleep(backoff)
                continue

            if intent is None:
                if time.monotonic() - idle_since > 60:
                    self.status, self.ok = "unknown", False
                    self.reason = "the brain published no intent for 60s"
                    return
                # Nothing to do is not a busy loop.
                time.sleep(backoff)
                continue

            idle_since = time.monotonic()
            self.artifacts.append("intents", {"claimed": intent.raw})
            self.event(f"intent {intent.intent_id}: {intent.goal_kind} "
                       f"({len(intent.steps)} steps)")

            outcome = self.executor.execute(intent)
            document = self.intents.report(
                intent, outcome.status, outcome.ok, reason=outcome.reason,
                started_at=outcome.started_at, final_position=outcome.final_position,
                distance_remaining=outcome.distance_remaining,
                observation_sequence=outcome.observation_sequence,
                details=outcome.details)
            self.artifacts.append("execution-results", document)
            self._record_control("intent_finished", intent_id=intent.intent_id,
                                 status=outcome.status,
                                 events_sent=self.input.events_sent)
            self.intent_log.append({
                "intent_id": intent.intent_id, "goal": intent.goal_kind,
                "status": outcome.status, "ok": outcome.ok, "reason": outcome.reason,
                "distance_remaining": outcome.distance_remaining,
            })
            self.event(f"  -> {outcome.status}: {outcome.reason}")

            if not outcome.ok and outcome.status in ("client_disconnected", "bridge_unavailable"):
                self.status, self.ok = outcome.status, False
                self.reason = outcome.reason
                return

            if self.config.artifacts.screenshots_on_failure and not outcome.ok:
                self._screenshot(f"failed-{intent.goal_kind}")

            executed += 1
            if self.max_intents and executed >= self.max_intents:
                self.status, self.ok = "reached", True
                self.reason = f"executed the requested {executed} intent(s)"
                return

    def run_scenario(self, steps) -> bool:
        """Execute a scripted acceptance scenario instead of the brain's intents.

        Used only by the acceptance runs. The brain is not consulted, and the
        intents come from ``scenario.py`` — but they go through the same
        executor, so what is being measured is still what a real client managed
        to do with a real body.
        """
        all_ok = True
        surprised: list[str] = []
        for step in steps:
            self.control.poll()
            if self.control.stopped:
                self.status, self.ok = "operator_stopped", False
                self.reason = self.control.stop_reason
                return False

            self.event(f"scenario step '{step.name}': {step.note}")
            outcome = self.executor.execute(step.intent)
            passed, detail = step.judge(outcome.status, outcome.ok)

            self.artifacts.append("execution-results", {
                "scenario_step": step.name, "status": outcome.status,
                "ok": outcome.ok, "reason": outcome.reason,
                "final_position": outcome.final_position,
                "distance_remaining": outcome.distance_remaining,
                "expected_ok": step.expect_ok,
                "expected_status": list(step.expect_status),
                "passed": passed, "details": outcome.details,
                "intent_id": step.intent.intent_id,
            })
            self.intent_log.append({
                "intent_id": step.intent.intent_id, "goal": step.name,
                "status": outcome.status, "ok": outcome.ok,
                "reason": outcome.reason,
                "distance_remaining": outcome.distance_remaining,
                "scenario_passed": passed,
            })
            self.event(f"  -> {outcome.status}: {outcome.reason} "
                       f"[{'as expected' if passed else 'UNEXPECTED: ' + detail}]")

            if not passed:
                self._screenshot(f"unexpected-{step.name}")
                surprised.append(step.name)
                if step.required:
                    all_ok = False
            elif not outcome.ok and self.config.artifacts.screenshots_on_failure:
                # An expected failure is a result worth a picture too.
                self._screenshot(f"expected-stop-{step.name}")

            if outcome.status in ("client_disconnected", "bridge_unavailable"):
                self.status, self.ok = outcome.status, False
                self.reason = outcome.reason
                return False

        self.status = "reached" if all_ok else "unknown"
        self.ok = all_ok
        if not all_ok:
            self.reason = "a scenario step did not behave as expected"
        elif surprised:
            # An optional step is allowed not to fail the run. It is not allowed
            # to disappear from the verdict: "everything behaved as expected"
            # printed above a step marked UNEXPECTED is a report that cannot be
            # trusted about anything else either.
            self.reason = ("every required step behaved as expected; "
                           f"optional steps did not: {', '.join(surprised)}")
        else:
            self.reason = "every scenario step behaved as expected"
        return all_ok

    def prepare(self) -> None:
        """Bring everything up without starting the intent loop."""
        self._start_display()
        self._start_client()
        self._start_input()
        self._connect_bridge()
        self._build_controllers()

    # --- teardown -------------------------------------------------------------------

    def _release_keys(self, cause: str) -> None:
        """Always first, on every path out of a run."""
        if self.input is None or self._keys_released:
            return
        released = self.input.release_all()
        self._keys_released = True
        if released:
            self._record_control("release_all", keys=released, cause=cause)
            self.log.info("released held keys: %s", ", ".join(released))

    def _screenshot(self, label: str) -> str:
        if not self.display:
            return ""
        path = self.artifacts.screenshot_path(label)
        if screenshot(self.display.display, path):
            self.log.info("screenshot for the human: %s", path)
            return str(path)
        return ""

    def _teardown(self, keep_open: bool) -> None:
        self._release_keys("teardown")

        if self.config.artifacts.screenshot_on_finish:
            self._screenshot("final")

        if self.input is not None:
            try:
                self.input.close()
            except Exception:  # noqa: BLE001
                pass

        if keep_open:
            # Let go without killing anything: the operator wants to look
            # around in the world the bot was standing in.
            self.event("--keep-open: leaving the client and display running for the operator")
            if self.client:
                self.client.detach()
            return

        if self.client:
            self.client.stop()
            self.event("client stopped")
        if self.display:
            self.display.stop()
            self.event("display stopped")

    # --- entry point ------------------------------------------------------------------

    def run(self, scenario_steps=None) -> dict:
        """Run the bot. With *scenario_steps*, run those instead of the brain's."""
        self.started = time.monotonic()
        previous_handlers = {}
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                previous_handlers[sig] = signal.signal(
                    sig, lambda *_: self.control.stop("interrupted"))
            except ValueError:  # pragma: no cover - not on the main thread
                pass

        self.event(f"run {self.run_id} starting in {self.config.display.mode} mode")
        failure = None
        try:
            self._start_display()
            self._start_client()
            self._start_input()
            self._connect_bridge()
            if scenario_steps is None:
                self._connect_brain()
            self._build_controllers()
            if scenario_steps is None:
                self.event("closed-loop execution begins")
                self._loop()
            else:
                self.event(f"scenario: {len(scenario_steps)} scripted step(s)")
                self.run_scenario(scenario_steps)
        except (DependencyMissing, DisplayError, ClientError, WindowNotFound,
                BridgeUnavailable, BridgeRefused, OperatorStopped, RuntimeError_) as exc:
            failure = exc
            self.status = getattr(exc, "code", "unknown")
            if self.status in ("runtime_error", "config_error"):
                self.status = "unknown"
            self.ok = False
            self.reason = str(exc)
            self.log.error("run failed: %s", exc)
        except Exception as exc:  # noqa: BLE001 - the report must exist regardless
            failure = exc
            self.status, self.ok = "unknown", False
            self.reason = f"unhandled error: {exc}"
            self.log.exception("run failed with an unhandled error")
        finally:
            keep_open = self.config.client.keep_open_after_run or (
                bool(failure) and self.config.client.keep_open_on_failure
                and self.config.display.mode == "visible")
            try:
                self._teardown(keep_open)
            except Exception:  # noqa: BLE001
                self.log.exception("teardown had a problem")
            for sig, handler in previous_handlers.items():
                try:
                    signal.signal(sig, handler)
                except ValueError:  # pragma: no cover
                    pass

        result = self._build_result(failure)
        self.artifacts.write_json("result.json", result)
        self.artifacts.write_summary(result)
        self.artifacts.close()
        prune_old_runs(self.config.artifacts_path, self.config.artifacts.keep_runs)
        return result

    def _build_result(self, failure) -> dict:
        metrics = {}
        for source in (self.bridge, self.intents, self.movement, self.interaction, self.executor):
            if source is not None:
                metrics.update(source.metrics())
        if self.input is not None:
            metrics["input_events_sent"] = self.input.events_sent
            metrics["input_backend"] = self.input.name

        return build_result(
            self.config, self.run_id,
            ok=self.ok, status=self.status, reason=self.reason,
            duration_seconds=round(time.monotonic() - self.started, 2),
            display=self.display.describe() if self.display else {},
            client=self.client.describe() if self.client else {},
            client_log_tail=self.client.log_tail() if self.client else [],
            timeline=self.timeline,
            intents=self.intent_log,
            metrics=metrics,
            error=failure.as_dict() if isinstance(failure, RuntimeError_) else (
                {"code": "unhandled", "message": str(failure)} if failure else None),
            artifacts_directory=str(self.artifacts.directory),
        )
