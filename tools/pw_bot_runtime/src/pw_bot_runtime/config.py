"""Runtime configuration: a TOML file, validated, with the password kept out of it.

Two rules shape this module.

The password is never a value in the config. The config holds a *path* to a file
containing one, that file must not be group- or world-readable, and the contents
are read once, at the moment the client is launched, into an argument list that
is never logged. There is no attribute on any object here that holds a password.

Every knob has a default and a checked range. A runtime that drives a real
client with a real body in a real world should not be one bad number away from
holding a key down for an hour.
"""

from __future__ import annotations

import os
import stat
import tomllib
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

from .errors import ConfigError

#: Substrings that must never appear in a log line, a report or an exception.
#: Used by :func:`redact` and asserted on by the tests.
SECRET_KEYS = ("password", "passwd", "secret", "token", "api_key")

REDACTED = "***redacted***"


def redact(value: Any) -> Any:
    """Return *value* with anything that looks like a secret replaced.

    Applied to every structure on its way into a log line or an artifact. It is
    deliberately blunt: a key whose name contains "password" loses its value
    whatever that value is, because a redactor that tries to be clever about
    which passwords are real is a redactor that eventually gets it wrong.
    """
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if any(marker in str(key).lower() for marker in SECRET_KEYS):
                # Keep the path, lose anything that could be the secret itself.
                out[key] = str(item) if "file" in str(key).lower() or "path" in str(key).lower() else REDACTED
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, (list, tuple)):
        return [redact(item) for item in value]
    return value


def _check(name: str, value: Any, kind: type, low=None, high=None):
    if not isinstance(value, kind) or isinstance(value, bool) is not (kind is bool):
        raise ConfigError(f"{name} must be {kind.__name__}, got {value!r}")
    if low is not None and value < low:
        raise ConfigError(f"{name} must be at least {low}, got {value}")
    if high is not None and value > high:
        raise ConfigError(f"{name} must be at most {high}, got {value}")
    return value


@dataclass
class ServerConfig:
    address: str = "127.0.0.1"
    port: int = 30000
    player_name: str = "pwbot"
    password_file: str = "./secrets/pwbot.password"
    world_path: str = "./data/worlds/perfectworld"

    def validate(self) -> None:
        _check("server.port", self.port, int, 1, 65535)
        if not self.player_name or "/" in self.player_name or ".." in self.player_name:
            raise ConfigError(f"server.player_name is not a usable name: {self.player_name!r}")


@dataclass
class ClientConfig:
    binary: str = "luanti"
    startup_timeout_seconds: int = 60
    display_size: str = "1280x720"
    keep_open_after_run: bool = False
    keep_open_on_failure: bool = True
    extra_args: list = field(default_factory=list)

    def validate(self) -> None:
        _check("client.startup_timeout_seconds", self.startup_timeout_seconds, int, 5, 600)
        try:
            width, height = self.display_size.lower().split("x")
            self.width, self.height = int(width), int(height)
        except Exception as exc:
            raise ConfigError(f"client.display_size must look like 1280x720, got {self.display_size!r}") from exc
        _check("client display width", self.width, int, 640, 7680)
        _check("client display height", self.height, int, 480, 4320)


@dataclass
class DisplayConfig:
    mode: str = "headless"
    visible_backend: str = "xephyr"
    allow_host_display_fallback: bool = False
    window_position_x: int = 100
    window_position_y: int = 100
    display_search_start: int = 90
    display_search_end: int = 120

    def validate(self) -> None:
        if self.mode not in ("headless", "visible"):
            raise ConfigError(f"display.mode must be headless or visible, got {self.mode!r}")
        if self.visible_backend not in ("xephyr", "mirror", "host"):
            raise ConfigError(
                f"display.visible_backend must be xephyr, mirror or host, got {self.visible_backend!r}")
        if self.visible_backend == "host" and not self.allow_host_display_fallback:
            raise ConfigError(
                "display.visible_backend=host requires display.allow_host_display_fallback=true; "
                "typing into the operator's own desktop is never a default")
        _check("display.display_search_start", self.display_search_start, int, 1, 1000)
        _check("display.display_search_end", self.display_search_end, int, 1, 1000)
        if self.display_search_end <= self.display_search_start:
            raise ConfigError("display.display_search_end must be greater than display_search_start")


@dataclass
class BridgeConfig:
    protocol: str = "pw_bot_bridge/v1"
    poll_interval_ms: int = 100
    request_timeout_ms: int = 3000

    def validate(self) -> None:
        _check("bridge.poll_interval_ms", self.poll_interval_ms, int, 10, 10000)
        _check("bridge.request_timeout_ms", self.request_timeout_ms, int, 100, 60000)


@dataclass
class BrainConfig:
    protocol: str = "pw_player_bot/v1"
    think_interval_ms: int = 250
    intent_timeout_seconds: int = 30

    def validate(self) -> None:
        _check("brain.think_interval_ms", self.think_interval_ms, int, 50, 60000)
        _check("brain.intent_timeout_seconds", self.intent_timeout_seconds, int, 1, 600)


@dataclass
class MovementConfig:
    position_tolerance: float = 0.55
    yaw_tolerance_degrees: float = 6.0
    stuck_timeout_seconds: float = 3.0
    maximum_action_seconds: float = 30.0
    progress_epsilon: float = 0.08
    #: Radians of yaw per pixel of horizontal pointer motion. The measured value
    #: for the project's own test client is 0.00349 (200 px produced 0.698 rad).
    #: Calibration lives here rather than in the brain: how hard to push a mouse
    #: is a fact about a client, not about a decision.
    yaw_radians_per_pixel: float = 0.00349
    yaw_gain: float = 0.9
    calibrate_yaw_on_start: bool = True
    control_tick_ms: int = 120

    def validate(self) -> None:
        _check("movement.position_tolerance", self.position_tolerance, float, 0.1, 5.0)
        _check("movement.yaw_tolerance_degrees", self.yaw_tolerance_degrees, float, 0.5, 90.0)
        _check("movement.stuck_timeout_seconds", self.stuck_timeout_seconds, float, 0.5, 120.0)
        _check("movement.maximum_action_seconds", self.maximum_action_seconds, float, 1.0, 600.0)
        _check("movement.progress_epsilon", self.progress_epsilon, float, 0.001, 5.0)
        _check("movement.yaw_radians_per_pixel", self.yaw_radians_per_pixel, float, 1e-5, 1.0)
        _check("movement.yaw_gain", self.yaw_gain, float, 0.05, 2.0)
        _check("movement.control_tick_ms", self.control_tick_ms, int, 20, 2000)


@dataclass
class InputConfig:
    backend: str = "auto"
    key_forward: str = "w"
    key_backward: str = "s"
    key_left: str = "a"
    key_right: str = "d"
    key_jump: str = "space"
    key_sneak: str = "shift"
    key_chat: str = "t"
    #: Left click is bound but never used for digging in v1. Breaking the world
    #: is not something a first walking bot should be able to do by accident.
    allow_left_click: bool = False

    def validate(self) -> None:
        if self.backend not in ("auto", "xtest", "xdotool"):
            raise ConfigError(f"input.backend must be auto, xtest or xdotool, got {self.backend!r}")


@dataclass
class ArtifactsConfig:
    directory: str = "./runtime/pw-bot-artifacts"
    screenshots_on_failure: bool = True
    screenshot_on_finish: bool = True
    keep_runs: int = 50

    def validate(self) -> None:
        _check("artifacts.keep_runs", self.keep_runs, int, 1, 10000)


@dataclass
class Config:
    server: ServerConfig = field(default_factory=ServerConfig)
    client: ClientConfig = field(default_factory=ClientConfig)
    display: DisplayConfig = field(default_factory=DisplayConfig)
    bridge: BridgeConfig = field(default_factory=BridgeConfig)
    brain: BrainConfig = field(default_factory=BrainConfig)
    movement: MovementConfig = field(default_factory=MovementConfig)
    input: InputConfig = field(default_factory=InputConfig)
    artifacts: ArtifactsConfig = field(default_factory=ArtifactsConfig)
    source_path: str = ""
    project_root: str = "."

    # --- derived paths -------------------------------------------------

    def _resolve(self, value: str) -> Path:
        path = Path(value).expanduser()
        if path.is_absolute():
            return path
        return (Path(self.project_root) / path).resolve()

    @property
    def world_path(self) -> Path:
        return self._resolve(self.server.world_path)

    @property
    def password_path(self) -> Path:
        return self._resolve(self.server.password_file)

    @property
    def artifacts_path(self) -> Path:
        return self._resolve(self.artifacts.directory)

    @property
    def bridge_spool(self) -> Path:
        return self.world_path / "pw_bot_bridge"

    @property
    def brain_spool(self) -> Path:
        return self.world_path / "pw_player_bot"

    def validate(self) -> None:
        for section in (self.server, self.client, self.display, self.bridge,
                        self.brain, self.movement, self.input, self.artifacts):
            section.validate()

    # --- the password ---------------------------------------------------

    def check_password_file(self) -> tuple[bool, str]:
        """Is the password file present and not readable by everyone?

        Returns ``(ok, detail)`` rather than raising, because ``doctor`` wants to
        report every problem at once and only ``run`` wants to stop at the first.
        """
        path = self.password_path
        if not path.exists():
            return False, f"missing: {path}"
        mode = path.stat().st_mode
        if mode & (stat.S_IRGRP | stat.S_IROTH | stat.S_IWGRP | stat.S_IWOTH):
            return False, f"permissions are {stat.filemode(mode)}, want 0600: chmod 600 {path}"
        return True, str(path)

    def read_password(self) -> str:
        """Read the password. The only place in the package that does.

        The value is handed straight to the client's argument list and is never
        stored on an object, logged, or put in a report.
        """
        ok, detail = self.check_password_file()
        if not ok:
            raise ConfigError(f"password file is unusable ({detail})")
        return self.password_path.read_text(encoding="utf-8").strip()

    # --- serialisation ---------------------------------------------------

    def as_redacted_dict(self) -> dict:
        return redact(asdict(self))


_SECTIONS = {
    "server": ServerConfig, "client": ClientConfig, "display": DisplayConfig,
    "bridge": BridgeConfig, "brain": BrainConfig, "movement": MovementConfig,
    "input": InputConfig, "artifacts": ArtifactsConfig,
}


def load_config(path: str | os.PathLike | None, project_root: str | os.PathLike = ".",
                overrides: dict | None = None) -> Config:
    """Load a TOML config, apply overrides, validate, and return it.

    An unknown key is an error rather than a shrug. A typo in a movement bound is
    exactly the kind of thing that silently does nothing and then surprises
    somebody at three in the morning.
    """
    raw: dict = {}
    if path is not None:
        file_path = Path(path).expanduser()
        if not file_path.exists():
            raise ConfigError(f"config file not found: {file_path}")
        try:
            raw = tomllib.loads(file_path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            raise ConfigError(f"config file is not valid TOML: {exc}") from exc

    config = Config(project_root=str(project_root), source_path=str(path) if path else "")

    for section_name, values in raw.items():
        if section_name not in _SECTIONS:
            raise ConfigError(f"unknown config section [{section_name}]")
        if not isinstance(values, dict):
            raise ConfigError(f"[{section_name}] must be a table")
        section = getattr(config, section_name)
        known = {f for f in section.__dataclass_fields__}
        for key, value in values.items():
            if key not in known:
                raise ConfigError(f"unknown key {section_name}.{key}")
            setattr(section, key, value)

    for dotted, value in (overrides or {}).items():
        if value is None:
            continue
        section_name, _, key = dotted.partition(".")
        if section_name not in _SECTIONS:
            raise ConfigError(f"unknown override section {dotted}")
        section = getattr(config, section_name)
        if key not in section.__dataclass_fields__:
            raise ConfigError(f"unknown override {dotted}")
        setattr(section, key, value)

    config.validate()
    return config
