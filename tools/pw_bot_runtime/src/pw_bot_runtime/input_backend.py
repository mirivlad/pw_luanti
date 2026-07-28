"""Sending keys and pointer motion to a real client, and the promise to stop.

The interface is small on purpose. Everything the bot can physically do reduces
to holding a key, releasing it, moving a pointer and clicking — the same set a
human has. There is no ``teleport``, no ``set_position``, no ``face``; if a verb
cannot be expressed as something a hand does, it does not belong here.

The one non-obvious requirement is :meth:`InputBackend.release_all`. A held key
outlives the process that pressed it: if the runtime crashes while walking
forward, the client keeps walking forward until something releases W. Every exit
path in this package goes through ``release_all`` before anything else, and the
backend tracks what it is holding so that promise can be kept without the caller
remembering.
"""

from __future__ import annotations

import abc
import shutil
import subprocess
import time
from typing import Iterable

from .errors import DependencyMissing, InputBackendError

#: Names used across the package, mapped per backend. Callers say "forward",
#: never "w" and never keycode 25.
NAMED_KEYS = ("forward", "backward", "left", "right", "jump", "sneak", "chat", "escape", "enter")


class InputBackend(abc.ABC):
    """Abstract input device attached to one display and one window."""

    name = "abstract"

    def __init__(self, display: str, window_id: str | None = None) -> None:
        self.display = display
        self.window_id = window_id
        self._held: set[str] = set()
        self.events_sent = 0

    # --- required of an implementation ---------------------------------

    @abc.abstractmethod
    def _key_down(self, key: str) -> None: ...

    @abc.abstractmethod
    def _key_up(self, key: str) -> None: ...

    @abc.abstractmethod
    def _pointer_move_relative(self, dx: int, dy: int) -> None: ...

    @abc.abstractmethod
    def _button(self, button: int, press: bool) -> None: ...

    @abc.abstractmethod
    def _pointer_warp(self, x: int, y: int) -> None: ...

    @abc.abstractmethod
    def type_text(self, text: str) -> None: ...

    def close(self) -> None:  # pragma: no cover - trivial in both backends
        self.release_all()

    # --- the shared surface ---------------------------------------------

    @property
    def held_keys(self) -> frozenset[str]:
        return frozenset(self._held)

    def key_down(self, key: str) -> None:
        self._key_down(key)
        self._held.add(key)
        self.events_sent += 1

    def key_up(self, key: str) -> None:
        self._key_up(key)
        self._held.discard(key)
        self.events_sent += 1

    def tap(self, key: str, hold_seconds: float = 0.05) -> None:
        self.key_down(key)
        time.sleep(hold_seconds)
        self.key_up(key)

    def release_all(self) -> list[str]:
        """Release every key this backend is holding. Never raises.

        Called from exception handlers and from ``finally`` blocks, where raising
        would replace a useful error with a useless one and leave the key held
        anyway.
        """
        released = []
        for key in sorted(self._held):
            try:
                self._key_up(key)
                released.append(key)
            except Exception:  # noqa: BLE001 - a stuck key beats a clean traceback
                pass
        self._held.clear()
        return released

    def move_pointer(self, dx: int, dy: int) -> None:
        if dx == 0 and dy == 0:
            return
        self._pointer_move_relative(dx, dy)
        self.events_sent += 1

    def warp_pointer(self, x: int, y: int) -> None:
        """Put the pointer at an absolute screen position.

        Needed before every click. Luanti reads *relative* motion to turn the
        head, so hundreds of pixels of look-around leave the X pointer far from
        where the view is aimed — often outside the client window entirely. A
        button event goes to whatever is under the pointer, so without this the
        clicks land on the root window and nothing happens, silently. Under a
        normal desktop the client's own pointer grab hides this; on a bare Xvfb
        with no window manager there is nothing to hide it.
        """
        self._pointer_warp(int(x), int(y))
        self.events_sent += 1

    def select_hotbar_slot(self, slot: int) -> None:
        """Select a hotbar slot by its number key.

        Used to put an empty slot in hand before interacting. What the bot is
        holding changes what "use" means: with a throwable in hand the item's own
        placement handler runs and the node under the crosshair is never asked,
        so a bot with snowballs throws snowballs at doors instead of opening
        them.
        """
        if not 1 <= slot <= 9:
            raise InputBackendError(f"hotbar slot {slot} does not exist")
        self.tap(f"slot{slot}", 0.06)

    def use(self) -> None:
        """Use / place: what a right click does, sent as a key.

        The client config binds `keymap_place` to a key precisely so this does
        not have to be a mouse button. A button goes to whatever is under the X
        pointer, and the pointer is not where the crosshair is looking.

        The hold is long on purpose. Luanti samples the place key once per
        rendered frame, and this client draws through software GL on an Xvfb
        display, where a frame can take a good fraction of a second — a 0.18 s
        press at the course door did nothing, while a 0.5 s press of the dig key
        destroyed a node. Duration was the difference, not the binding.

        Holding this long would normally repeat the action, and two activations
        on a door means opened and closed again — indistinguishable from nothing
        happening. `client.conf` pins `repeat_place_time` to its maximum so that
        one hold, however long, is one action.
        """
        self.tap("place", 0.5)

    def right_click(self) -> None:
        """The mouse-button form. Kept for completeness and not used to interact.

        On an isolated display with no window manager this is unreliable for the
        reason described in :meth:`use`, which is exactly why the runtime binds a
        key instead.
        """
        self._button(3, True)
        time.sleep(0.04)
        self._button(3, False)
        self.events_sent += 2

    def left_click(self) -> None:
        """Present for completeness and refused by default at the caller.

        See ``input.allow_left_click``: a first walking bot that can dig is a bot
        that can quietly destroy the village it was sent to inspect.
        """
        self._button(1, True)
        time.sleep(0.04)
        self._button(1, False)
        self.events_sent += 2

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class XdotoolBackend(InputBackend):
    """Input through the ``xdotool`` command line tool.

    One subprocess per event, which is the reason it is not the default: at a
    control tick of 120 ms it is fine, but it is measurably slower than talking
    to the X server directly, and every event is a fork.
    """

    name = "xdotool"

    KEYS = {
        "forward": "w", "backward": "s", "left": "a", "right": "d",
        "jump": "space", "sneak": "shift", "chat": "t",
        "escape": "Escape", "enter": "Return",
        "place": "r", "dig": "f",
        **{f"slot{n}": str(n) for n in range(1, 10)},
    }

    def __init__(self, display: str, window_id: str | None = None) -> None:
        super().__init__(display, window_id)
        if not shutil.which("xdotool"):
            raise DependencyMissing(
                "xdotool is not installed",
                install_hint="sudo apt-get install -y xdotool")

    def _run(self, *args: str) -> None:
        result = subprocess.run(
            ["xdotool", *args],
            env={"DISPLAY": self.display, "PATH": "/usr/bin:/bin"},
            capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            raise InputBackendError(
                f"xdotool {' '.join(args)} failed: {result.stderr.strip()}")

    def _resolve(self, key: str) -> str:
        return self.KEYS.get(key, key)

    def _key_down(self, key: str) -> None:
        self._run("keydown", self._resolve(key))

    def _key_up(self, key: str) -> None:
        self._run("keyup", self._resolve(key))

    def _pointer_move_relative(self, dx: int, dy: int) -> None:
        self._run("mousemove_relative", "--", str(dx), str(dy))

    def _button(self, button: int, press: bool) -> None:
        self._run("mousedown" if press else "mouseup", str(button))

    def _pointer_warp(self, x: int, y: int) -> None:
        self._run("mousemove", "--sync", str(x), str(y))

    def type_text(self, text: str) -> None:
        self._run("type", "--delay", "40", text)


class XTestBackend(InputBackend):
    """Input through the X11 XTEST extension, via python-xlib.

    Preferred because it holds one connection open for the life of the run
    instead of forking a process per key, and because it fails loudly at connect
    time rather than per event.

    The events XTEST produces are indistinguishable to the client from events
    made by a physical keyboard, which is the property that matters: the bot is
    not simulating input at the application layer, it is producing input.
    """

    name = "xtest"

    KEYSYMS = {
        "forward": "w", "backward": "s", "left": "a", "right": "d",
        "jump": "space", "sneak": "Shift_L", "chat": "t",
        "escape": "Escape", "enter": "Return",
        "place": "r", "dig": "f",
        **{f"slot{n}": str(n) for n in range(1, 10)},
    }

    def __init__(self, display: str, window_id: str | None = None) -> None:
        super().__init__(display, window_id)
        try:
            from Xlib import X, XK, display as xdisplay  # noqa: F401
            from Xlib.ext import xtest
        except ImportError as exc:
            raise DependencyMissing(
                "python-xlib is not installed",
                install_hint="sudo apt-get install -y python3-xlib") from exc

        self._X = X
        self._XK = XK
        self._xtest = xtest
        try:
            self._display = xdisplay.Display(display)
        except Exception as exc:  # noqa: BLE001 - Xlib raises many shapes
            raise InputBackendError(f"cannot open display {display}: {exc}") from exc
        if not self._display.has_extension("XTEST"):
            raise DependencyMissing(
                f"display {display} has no XTEST extension",
                install_hint="use a display started by Xvfb or Xephyr")

    def _keycode(self, key: str) -> int:
        name = self.KEYSYMS.get(key, key)
        keysym = self._XK.string_to_keysym(name)
        if keysym == 0:
            raise InputBackendError(f"no keysym for {key!r}")
        code = self._display.keysym_to_keycode(keysym)
        if code == 0:
            raise InputBackendError(f"no keycode for {key!r}")
        return code

    def _key_down(self, key: str) -> None:
        self._xtest.fake_input(self._display, self._X.KeyPress, self._keycode(key))
        self._display.sync()

    def _key_up(self, key: str) -> None:
        self._xtest.fake_input(self._display, self._X.KeyRelease, self._keycode(key))
        self._display.sync()

    def _pointer_move_relative(self, dx: int, dy: int) -> None:
        self._xtest.fake_input(self._display, self._X.MotionNotify, detail=True, x=dx, y=dy)
        self._display.sync()

    def _button(self, button: int, press: bool) -> None:
        event = self._X.ButtonPress if press else self._X.ButtonRelease
        self._xtest.fake_input(self._display, event, button)
        self._display.sync()

    def _pointer_warp(self, x: int, y: int) -> None:
        # detail=False means the coordinates are absolute rather than a delta.
        self._xtest.fake_input(self._display, self._X.MotionNotify, detail=False, x=x, y=y)
        self._display.sync()

    def type_text(self, text: str) -> None:
        for char in text:
            if char == " ":
                self.tap("space", 0.02)
                continue
            keysym = self._XK.string_to_keysym(char)
            code = self._display.keysym_to_keycode(keysym) if keysym else 0
            if code == 0:
                continue
            self._xtest.fake_input(self._display, self._X.KeyPress, code)
            self._display.sync()
            time.sleep(0.02)
            self._xtest.fake_input(self._display, self._X.KeyRelease, code)
            self._display.sync()
            time.sleep(0.02)

    def close(self) -> None:
        self.release_all()
        try:
            self._display.close()
        except Exception:  # noqa: BLE001
            pass


def available_backends() -> dict[str, bool]:
    """Which backends could be constructed here, without constructing them."""
    have_xdotool = shutil.which("xdotool") is not None
    try:
        import Xlib  # noqa: F401
        have_xtest = True
    except ImportError:
        have_xtest = False
    return {"xtest": have_xtest, "xdotool": have_xdotool}


def make_backend(preference: str, display: str, window_id: str | None = None) -> InputBackend:
    """Build a backend, honouring an explicit choice and picking sensibly for ``auto``."""
    order: Iterable[str]
    if preference == "auto":
        order = ("xtest", "xdotool")
    else:
        order = (preference,)

    problems = []
    for name in order:
        try:
            if name == "xtest":
                return XTestBackend(display, window_id)
            if name == "xdotool":
                return XdotoolBackend(display, window_id)
            raise InputBackendError(f"unknown input backend {name!r}")
        except (DependencyMissing, InputBackendError) as exc:
            problems.append(f"{name}: {exc}")
    raise DependencyMissing(
        "no usable input backend: " + "; ".join(problems),
        install_hint="sudo apt-get install -y python3-xlib xdotool")
