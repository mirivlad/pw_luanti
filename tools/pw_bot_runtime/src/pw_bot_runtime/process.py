"""Starting a real Luanti client, finding its window, and proving it is the right one.

Two things here are worth more attention than their size suggests.

**The password never becomes an argument.** Luanti accepts ``--password-file``,
so the runtime passes a path and the client reads it. The password does not
appear in ``ps``, in the process's own command line, in the runtime log, or in
any artifact. The file is checked for 0600 before the client is launched.

**A window is not trusted because it is the only one.** Input goes to a window
whose ``_NET_WM_PID`` is the client this runtime started, verified after the
window is found. On an isolated display that is belt and braces; on the host
display it is the only thing standing between the bot and the operator's editor.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .config import Config
from .errors import ClientError, DependencyMissing, WindowNotFound


class LuantiClient:
    """One real Luanti client process on one display."""

    def __init__(self, config: Config, display: str, log_path: Path) -> None:
        self.config = config
        self.display = display
        self.log_path = log_path
        self.process: subprocess.Popen | None = None
        self.window_id: str | None = None
        self._log_handle = None

    # --- lifecycle -------------------------------------------------------

    def start(self) -> subprocess.Popen:
        binary = shutil.which(self.config.client.binary) or self.config.client.binary
        if not Path(binary).exists():
            raise DependencyMissing(
                f"Luanti client not found: {self.config.client.binary}",
                install_hint="sudo apt-get install -y luanti  # or set client.binary")

        ok, detail = self.config.check_password_file()
        if not ok:
            raise ClientError(f"cannot start the client: {detail}")

        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log_handle = self.log_path.open("wb")

        argv = [binary, "--go"]
        if self.config.client.config_file:
            client_config = self.config._resolve(self.config.client.config_file)
            if client_config.exists():
                argv += ["--config", str(client_config)]
        argv += [
            "--address", self.config.server.address,
            "--port", str(self.config.server.port),
            "--name", self.config.server.player_name,
            # A path, never the secret. This is the whole reason the runtime
            # requires a password *file* rather than accepting a password.
            "--password-file", str(self.config.password_path),
            *self.config.client.extra_args,
        ]
        env = dict(os.environ, DISPLAY=self.display)
        env.pop("XAUTHORITY", None)

        self.process = subprocess.Popen(
            argv, env=env, stdout=self._log_handle, stderr=subprocess.STDOUT)
        return self.process

    def is_alive(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def stop(self, timeout: float = 8.0) -> None:
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if self._log_handle:
            self._log_handle.close()
            self._log_handle = None

    def detach(self) -> None:
        """Stop managing the client but leave it running.

        This is what ``--keep-open`` does. The runtime lets go of the client and
        the display so an operator can walk around and look at whatever the bot
        was looking at when it stopped.
        """
        if self._log_handle:
            self._log_handle.close()
            self._log_handle = None
        self.process = None

    # --- the window ------------------------------------------------------

    def find_window(self, timeout: float = 30.0) -> str:
        """Find the client's window and verify it belongs to our process."""
        if not shutil.which("xdotool"):
            raise DependencyMissing("xdotool is needed to identify the client window",
                                    install_hint="sudo apt-get install -y xdotool")
        if not self.process:
            raise ClientError("the client has not been started")

        pid = str(self.process.pid)
        deadline = time.time() + timeout
        last_error = ""
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise ClientError(
                    f"the client exited with code {self.process.returncode} before showing a window",
                    tail=self.log_tail())
            result = subprocess.run(
                ["xdotool", "search", "--onlyvisible", "--pid", pid],
                env={"DISPLAY": self.display, "PATH": "/usr/bin:/bin"},
                capture_output=True, text=True)
            candidates = [line.strip() for line in result.stdout.splitlines() if line.strip()]
            for window in candidates:
                if self._window_pid(window) == pid:
                    self.window_id = window
                    return window
            last_error = result.stderr.strip()
            time.sleep(0.4)

        raise WindowNotFound(
            f"no window on {self.display} belongs to client pid {pid}",
            display=self.display, stderr=last_error)

    def _window_pid(self, window: str) -> str:
        result = subprocess.run(
            ["xdotool", "getwindowpid", window],
            env={"DISPLAY": self.display, "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True)
        return result.stdout.strip()

    def verify_window(self) -> bool:
        """Re-check that the window we are typing into is still ours."""
        if not self.window_id or not self.process:
            return False
        return self._window_pid(self.window_id) == str(self.process.pid)

    def focus_window(self) -> None:
        """Give the client keyboard focus inside its own display."""
        if not self.window_id:
            return
        env = {"DISPLAY": self.display, "PATH": "/usr/bin:/bin"}
        for args in (["windowactivate", self.window_id],
                     ["windowfocus", self.window_id],
                     ["windowraise", self.window_id]):
            subprocess.run(["xdotool", *args], env=env, capture_output=True, text=True)

    def window_centre(self) -> tuple[int, int] | None:
        """Screen coordinates of the middle of the client window."""
        if not self.window_id:
            return None
        result = subprocess.run(
            ["xdotool", "getwindowgeometry", "--shell", self.window_id],
            env={"DISPLAY": self.display, "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True)
        values = {}
        for line in result.stdout.splitlines():
            key, _, value = line.partition("=")
            if value.strip().lstrip("-").isdigit():
                values[key.strip()] = int(value)
        if not {"X", "Y", "WIDTH", "HEIGHT"} <= values.keys():
            return None
        return (values["X"] + values["WIDTH"] // 2,
                values["Y"] + values["HEIGHT"] // 2)

    def window_name(self) -> str:
        if not self.window_id:
            return ""
        result = subprocess.run(
            ["xdotool", "getwindowname", self.window_id],
            env={"DISPLAY": self.display, "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True)
        return result.stdout.strip()

    # --- diagnostics -----------------------------------------------------

    def log_tail(self, lines: int = 12) -> list[str]:
        """Last few client log lines, with the known localization noise dropped.

        Luanti logs a screenful of "Don't know how to load file 'xx.po'" on every
        start. Leaving it in would bury whatever actually went wrong.
        """
        if not self.log_path.exists():
            return []
        try:
            text = self.log_path.read_text(encoding="utf-8", errors="replace")
        except OSError:  # pragma: no cover
            return []
        useful = [line for line in text.splitlines()
                  if ".po\"" not in line and "po_file" not in line]
        return useful[-lines:]

    def describe(self) -> dict:
        return {
            "binary": self.config.client.binary,
            "display": self.display,
            "pid": self.process.pid if self.process else None,
            "window_id": self.window_id,
            "window_name": self.window_name() if self.window_id else "",
            "alive": self.is_alive(),
            "log": str(self.log_path),
        }


def screenshot(display: str, target: Path) -> bool:
    """Capture the display for a human to look at.

    Diagnostic only. Nothing in this package reads an image back: the bot's
    perception comes from the bridge, and a screenshot it could parse would be
    the beginning of exactly the architecture this project refuses to build.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    env = {"DISPLAY": display, "PATH": "/usr/bin:/bin"}
    for argv in (["import", "-window", "root", str(target)],
                 ["scrot", "-o", str(target)]):
        if not shutil.which(argv[0]):
            continue
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=20)
        if result.returncode == 0 and target.exists():
            return True
    return False
