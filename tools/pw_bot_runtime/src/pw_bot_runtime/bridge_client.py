"""Asking the bridge what the player can perceive, over the file spool.

This is the runtime's *only* source of knowledge about the world. It does not
read the map, does not open the world database, and does not look at the screen.
If the bridge cannot answer, the runtime does not know, and it says so rather
than filling the gap with an assumption.

Requests are written atomically — temporary file, then rename — so the server
never reads half a document. Every request gets a unique id, and the id is also
the response file name, so a slow answer to an abandoned question cannot be
mistaken for the answer to the current one.
"""

from __future__ import annotations

import json
import math
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from .errors import BridgeRefused, BridgeUnavailable

PROTOCOL = "pw_bot_bridge/v1"


@dataclass(frozen=True)
class SelfState:
    """What the bot can know about its own body, this instant."""

    x: float
    y: float
    z: float
    yaw: float
    pitch: float
    on_ground: bool
    in_liquid: bool
    hp: float
    #: Name of the item in hand, or "" for an empty hand. What is held decides
    #: what "use" means, so this is not a curiosity: with a throwable in hand the
    #: item's own handler runs and the node under the crosshair is never asked.
    wielded_item: str
    sequence: int
    raw: dict

    @property
    def position(self) -> tuple[float, float, float]:
        return (self.x, self.y, self.z)

    def ground_distance_to(self, target) -> float:
        tx, tz = _xz(target)
        return math.hypot(tx - self.x, tz - self.z)


def _xz(target) -> tuple[float, float]:
    if isinstance(target, dict):
        return float(target["x"]), float(target["z"])
    return float(target[0]), float(target[-1])


def _as_bool(value) -> bool:
    return value is True


class BridgeClient:
    """A conversation with pw_bot_bridge through ``<worldpath>/pw_bot_bridge``."""

    def __init__(self, spool_root: Path, player_name: str,
                 poll_interval_ms: int = 100, request_timeout_ms: int = 3000,
                 logger=None) -> None:
        self.root = Path(spool_root)
        self.player_name = player_name
        self.poll_interval = poll_interval_ms / 1000.0
        self.timeout = request_timeout_ms / 1000.0
        self.log = logger
        self.requests_sent = 0
        self.responses_received = 0
        self.latencies: list[float] = []
        self._session_prefix = uuid.uuid4().hex[:8]
        self._counter = 0

    # --- paths ------------------------------------------------------------

    @property
    def requests_dir(self) -> Path:
        return self.root / "requests" / self.player_name

    @property
    def responses_dir(self) -> Path:
        return self.root / "responses" / self.player_name

    def is_ready(self) -> tuple[bool, str]:
        """Is the spool there and writable? Used by ``doctor`` and at startup."""
        if not self.root.exists():
            return False, f"no bridge spool at {self.root} (is the transport started?)"
        if not self.requests_dir.exists():
            return False, (f"no request directory for {self.player_name}; register the bot "
                           f"and run /pw_bot_bridge_transport start")
        if not os.access(self.requests_dir, os.W_OK):
            return False, f"{self.requests_dir} is not writable"
        return True, str(self.root)

    # --- the round trip ----------------------------------------------------

    def _next_id(self) -> str:
        self._counter += 1
        return f"rt-{self._session_prefix}-{self._counter}"

    def request(self, operation: str, parameters: dict | None = None,
                timeout: float | None = None) -> dict:
        """Send one request and wait for its answer.

        Raises :class:`BridgeUnavailable` when nothing answers in time and
        :class:`BridgeRefused` when the bridge answers with an error. Those are
        genuinely different situations: the first means the runtime is blind,
        the second means it asked something it was not allowed to ask.
        """
        request_id = self._next_id()
        payload = {
            "protocol": PROTOCOL,
            "request_id": request_id,
            "operation": operation,
            "parameters": parameters or {},
        }
        self.requests_dir.mkdir(parents=True, exist_ok=True)
        target = self.requests_dir / f"{request_id}.json"
        temporary = self.requests_dir / f".{request_id}.json.tmp"
        temporary.write_text(json.dumps(payload), encoding="utf-8")
        os.replace(temporary, target)
        self.requests_sent += 1

        started = time.monotonic()
        deadline = started + (timeout if timeout is not None else self.timeout)
        response_path = self.responses_dir / f"{request_id}.json"
        while time.monotonic() < deadline:
            if response_path.exists():
                try:
                    document = json.loads(response_path.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError):
                    # The bridge writes atomically, so this is a torn read only
                    # in theory; try once more rather than failing the run.
                    time.sleep(self.poll_interval)
                    continue
                finally:
                    try:
                        response_path.unlink()
                    except OSError:
                        pass
                elapsed = time.monotonic() - started
                self.latencies.append(elapsed)
                self.responses_received += 1
                if not document.get("ok"):
                    error = document.get("error") or {}
                    raise BridgeRefused(
                        f"{operation} refused: {error.get('code')} {error.get('message', '')}".strip(),
                        error_code=str(error.get("code", "")), operation=operation)
                return document.get("data") or {}
            time.sleep(self.poll_interval)

        # Do not leave an unanswered question lying around for the bridge to
        # answer later, when nobody is listening for it any more.
        try:
            target.unlink()
        except OSError:
            pass
        raise BridgeUnavailable(
            f"{operation} was not answered within {deadline - started:.1f}s",
            operation=operation, request_id=request_id)

    # --- the operations the runtime is allowed to use ----------------------

    def self_state(self) -> SelfState:
        """Proprioception: where the body is and which way it faces."""
        data = self.request("get_self_state")
        state = data.get("self_state") or {}
        position = state.get("position") or {}
        return SelfState(
            x=float(position.get("x", 0.0)),
            y=float(position.get("y", 0.0)),
            z=float(position.get("z", 0.0)),
            yaw=float(state.get("yaw", 0.0)),
            pitch=float(state.get("pitch", 0.0)),
            on_ground=_as_bool(state.get("on_ground")),
            in_liquid=_as_bool(state.get("in_liquid")),
            hp=float(state.get("hp", 20)),
            wielded_item=str(state.get("wielded_item") or ""),
            sequence=int(data.get("sequence", 0) or 0),
            raw=data,
        )

    def observe(self, profile: str = "navigation") -> dict:
        return self.request("observe", {"profile": profile})

    def inspect_target(self) -> dict:
        """What the crosshair is pointing at, if anything."""
        return self.request("inspect_target")

    def find_visible_feature(self, feature: str) -> dict:
        return self.request("find_visible_feature", {"feature": feature})

    def wait_for_player(self, timeout: float = 60.0, interval: float = 1.0) -> SelfState:
        """Block until the bridge will talk about a connected player.

        Used once at startup. A client that has launched is not yet a player who
        has joined, and the difference is several seconds of world loading.
        """
        deadline = time.time() + timeout
        last = "never answered"
        while time.time() < deadline:
            try:
                return self.self_state()
            except BridgeRefused as exc:
                last = exc.error_code or str(exc)
                if exc.error_code not in ("player_not_connected", "bot_not_registered",
                                          "bot_disabled", "session_missing"):
                    raise
            except BridgeUnavailable as exc:
                last = str(exc)
            time.sleep(interval)
        raise BridgeUnavailable(
            f"{self.player_name} did not become observable within {timeout:.0f}s (last: {last})")

    # --- metrics -----------------------------------------------------------

    def metrics(self) -> dict:
        latencies = sorted(self.latencies)
        def percentile(fraction: float) -> float:
            if not latencies:
                return 0.0
            index = min(len(latencies) - 1, int(len(latencies) * fraction))
            return round(latencies[index] * 1000, 2)
        return {
            "requests_sent": self.requests_sent,
            "responses_received": self.responses_received,
            "observation_latency_ms_p50": percentile(0.5),
            "observation_latency_ms_p95": percentile(0.95),
            "observation_latency_ms_max": round(max(latencies) * 1000, 2) if latencies else 0.0,
        }
