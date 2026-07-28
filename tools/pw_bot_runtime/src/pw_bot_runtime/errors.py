"""Failures the runtime can have, named so a report can say which one happened.

Every error carries a machine-readable ``code``. The codes are the vocabulary a
test asserts on and an operator greps for; the human message is free to change
without breaking either.
"""

from __future__ import annotations


class RuntimeError_(Exception):
    """Base for everything this package raises.

    Named with a trailing underscore so it never shadows the builtin. Nothing
    outside this module should need the name: catch the subclasses.
    """

    code = "runtime_error"

    def __init__(self, message: str, **details: object) -> None:
        super().__init__(message)
        self.message = message
        self.details = details

    def as_dict(self) -> dict:
        return {"code": self.code, "message": self.message, "details": self.details}


class ConfigError(RuntimeError_):
    """The configuration is unusable, and guessing would be worse than stopping."""

    code = "config_error"


class DependencyMissing(RuntimeError_):
    """A required external program is not installed."""

    code = "dependency_missing"

    def __init__(self, message: str, install_hint: str = "", **details: object) -> None:
        super().__init__(message, **details)
        self.install_hint = install_hint

    def as_dict(self) -> dict:
        out = super().as_dict()
        out["install_hint"] = self.install_hint
        return out


class DisplayError(RuntimeError_):
    """No display could be started, or the one that started went away."""

    code = "display_error"


class ClientError(RuntimeError_):
    """The Luanti client failed to start, failed to connect, or exited."""

    code = "client_error"


class ClientDisconnected(ClientError):
    """The client was running and is no longer connected to the server."""

    code = "client_disconnected"


class WindowNotFound(RuntimeError_):
    """The client's window could not be identified.

    This is fatal rather than recoverable on purpose. Input is only ever sent to
    a window whose process is the client the runtime started; a runtime that
    cannot prove which window that is must not type anywhere.
    """

    code = "window_not_found"


class BridgeUnavailable(RuntimeError_):
    """The perception spool did not answer."""

    code = "bridge_unavailable"


class BridgeRefused(RuntimeError_):
    """The bridge answered, and the answer was no."""

    code = "bridge_refused"

    def __init__(self, message: str, error_code: str = "", **details: object) -> None:
        super().__init__(message, **details)
        self.error_code = error_code

    def as_dict(self) -> dict:
        out = super().as_dict()
        out["bridge_error_code"] = self.error_code
        return out


class InputBackendError(RuntimeError_):
    """A key or pointer event could not be delivered."""

    code = "input_backend_error"


class OperatorStopped(RuntimeError_):
    """A human asked the run to stop."""

    code = "operator_stopped"


class IntentInvalid(RuntimeError_):
    """A document in the intent spool is not an intent this runtime can execute."""

    code = "intent_invalid"
