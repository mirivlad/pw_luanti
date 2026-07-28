"""Isolated X displays: where the client runs and where the input goes.

The runtime never types into the operator's desktop. Every backend below either
creates a display of its own or refuses, and the one that can use the host
display is off unless a human turned it on in writing.

Three backends:

``XvfbDisplay``
    Headless. A virtual framebuffer nobody is looking at. The default, and what
    tests and long runs use.

``XephyrDisplay``
    Visible. A nested X server inside a window on the operator's desktop. The
    client runs inside it, so the operator watches a real client doing real
    things while the input still lands in a display of its own.

``HostDisplay``
    The operator's own ``$DISPLAY``. Off by default, requires an explicit config
    flag, and even then input is only ever addressed to a window whose process
    is the client the runtime started.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .errors import DependencyMissing, DisplayError


def _x_socket(number: int) -> Path:
    return Path(f"/tmp/.X11-unix/X{number}")


def find_free_display(start: int = 90, end: int = 120) -> int:
    """First display number with no X socket and no lock file.

    Racy in principle: two runtimes could pick the same number in the moment
    between the check and the server starting. The X server itself refuses the
    second one, and the caller reports that rather than pretending it owns a
    display it does not.
    """
    for number in range(start, end):
        if not _x_socket(number).exists() and not Path(f"/tmp/.X{number}-lock").exists():
            return number
    raise DisplayError(f"no free X display between :{start} and :{end}")


class DisplayBackend:
    """A display the client can run on."""

    name = "abstract"
    #: True when input sent here can reach windows the runtime did not start.
    shared_with_operator = False

    def __init__(self, width: int, height: int) -> None:
        self.width, self.height = width, height
        self.display = ""
        self.process: subprocess.Popen | None = None

    def start(self) -> str:
        raise NotImplementedError

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:  # pragma: no cover - slow teardown
                self.process.kill()
        self.process = None

    def is_alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def describe(self) -> dict:
        return {
            "backend": self.name,
            "display": self.display,
            "width": self.width,
            "height": self.height,
            "shared_with_operator": self.shared_with_operator,
            "pid": self.process.pid if self.process else None,
        }

    def _wait_for_socket(self, number: int, timeout: float = 15.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if _x_socket(number).exists():
                # The socket appearing is not the same as the server answering.
                time.sleep(0.4)
                return
            if self.process and self.process.poll() is not None:
                out = ""
                if self.process.stderr:
                    out = self.process.stderr.read()[:400] if not self.process.stderr.closed else ""
                raise DisplayError(f"{self.name} exited before the display was ready: {out}")
            time.sleep(0.15)
        raise DisplayError(f"{self.name} did not create :{number} within {timeout}s")

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()
        return False


class XvfbDisplay(DisplayBackend):
    name = "xvfb"

    def __init__(self, width: int, height: int, search: tuple[int, int] = (90, 120)) -> None:
        super().__init__(width, height)
        self.search = search

    def start(self) -> str:
        if not shutil.which("Xvfb"):
            raise DependencyMissing("Xvfb is not installed",
                                    install_hint="sudo apt-get install -y xvfb")
        number = find_free_display(*self.search)
        self.display = f":{number}"
        self.process = subprocess.Popen(
            ["Xvfb", self.display, "-screen", "0", f"{self.width}x{self.height}x24",
             "-nolisten", "tcp"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self._wait_for_socket(number)
        return self.display


class XephyrDisplay(DisplayBackend):
    """A nested X server shown in a window on the operator's desktop.

    The operator sees everything the bot does, in real time, and the bot's keys
    and pointer never leave the nested server. Closing the Xephyr window ends
    the display, which the run treats as the operator pulling the plug.
    """

    name = "xephyr"
    shared_with_operator = False

    def __init__(self, width: int, height: int, parent_display: str | None = None,
                 position: tuple[int, int] = (100, 100),
                 search: tuple[int, int] = (90, 120)) -> None:
        super().__init__(width, height)
        self.parent_display = parent_display or os.environ.get("DISPLAY", "")
        self.position = position
        self.search = search

    def start(self) -> str:
        if not shutil.which("Xephyr"):
            raise DependencyMissing(
                "Xephyr is not installed, so there is nothing to show a visible run in",
                install_hint="sudo apt-get install -y xserver-xephyr")
        if not self.parent_display:
            raise DisplayError(
                "visible mode needs a desktop to open a window on, and DISPLAY is not set")
        number = find_free_display(*self.search)
        self.display = f":{number}"
        env = dict(os.environ, DISPLAY=self.parent_display)
        self.process = subprocess.Popen(
            ["Xephyr", self.display, "-screen", f"{self.width}x{self.height}",
             "-title", "PW Bot — live client", "-resizeable", "-nolisten", "tcp"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self._wait_for_socket(number)
        return self.display

    def describe(self) -> dict:
        out = super().describe()
        out["parent_display"] = self.parent_display
        return out


class MirroredXvfbDisplay(XvfbDisplay):
    """Headless display plus a read-only live view for the operator.

    The fallback when Xephyr is unavailable. The client runs on Xvfb exactly as
    in a headless run, and ``ffplay`` grabs that display into a window on the
    desktop. The mirror forwards nothing, so it is if anything stricter than
    Xephyr: there is no path at all from the operator's keyboard to the client.
    The cost is a video encode in the loop and visibly higher latency.
    """

    name = "mirror"

    def __init__(self, width: int, height: int, parent_display: str | None = None,
                 search: tuple[int, int] = (90, 120)) -> None:
        super().__init__(width, height, search)
        self.parent_display = parent_display or os.environ.get("DISPLAY", "")
        self.viewer: subprocess.Popen | None = None

    def start(self) -> str:
        display = super().start()
        if not shutil.which("ffplay"):
            raise DependencyMissing(
                "ffplay is not installed, so the mirror has nothing to draw with",
                install_hint="sudo apt-get install -y ffmpeg")
        env = dict(os.environ, DISPLAY=self.parent_display)
        self.viewer = subprocess.Popen(
            ["ffplay", "-loglevel", "error", "-window_title", "PW Bot — live client (mirror)",
             "-f", "x11grab", "-framerate", "15", "-video_size", f"{self.width}x{self.height}",
             "-i", f"{display}.0"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return display

    def stop(self) -> None:
        if self.viewer and self.viewer.poll() is None:
            self.viewer.terminate()
            try:
                self.viewer.wait(timeout=3)
            except subprocess.TimeoutExpired:  # pragma: no cover
                self.viewer.kill()
        self.viewer = None
        super().stop()

    def describe(self) -> dict:
        out = super().describe()
        out["mirror_pid"] = self.viewer.pid if self.viewer else None
        out["parent_display"] = self.parent_display
        return out


class HostDisplay(DisplayBackend):
    """The operator's own display. Off unless explicitly allowed."""

    name = "host"
    shared_with_operator = True

    def start(self) -> str:
        self.display = os.environ.get("DISPLAY", "")
        if not self.display:
            raise DisplayError("DISPLAY is not set, so there is no host display to use")
        return self.display

    def stop(self) -> None:
        return None

    def is_alive(self) -> bool:
        return True


def make_display(mode: str, backend: str, width: int, height: int,
                 allow_host: bool, position: tuple[int, int] = (100, 100),
                 search: tuple[int, int] = (90, 120)) -> DisplayBackend:
    """Choose a display backend from the configuration.

    Visible mode prefers Xephyr and falls back to the mirror when Xephyr is not
    installed, because an operator who asked to watch should get to watch. It
    never falls back to the host display: that is a different risk, not a
    smaller one, and it needs a human decision rather than a default.
    """
    if mode == "headless":
        return XvfbDisplay(width, height, search)

    override = os.environ.get("PW_BOT_VISIBLE_BACKEND")
    if override:
        if override not in ("xephyr", "mirror", "host"):
            raise DisplayError(
                "PW_BOT_VISIBLE_BACKEND must be xephyr, mirror or host, "
                f"got {override!r}")
        backend = override

    if backend == "host":
        if not allow_host:
            raise DisplayError(
                "the host display is only usable when display.allow_host_display_fallback "
                "is true; typing into the operator's own desktop is never a default")
        return HostDisplay(width, height)

    if backend == "mirror":
        return MirroredXvfbDisplay(width, height, search=search)

    if shutil.which("Xephyr"):
        return XephyrDisplay(width, height, position=position, search=search)
    if shutil.which("ffplay"):
        return MirroredXvfbDisplay(width, height, search=search)
    raise DependencyMissing(
        "visible mode needs Xephyr, or ffplay for the mirror fallback",
        install_hint="sudo apt-get install -y xserver-xephyr")
