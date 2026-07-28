"""pw_bot_runtime — the third part of PW Bot: the part with a body.

    pw_bot_bridge     perceives    -- never acts
    pw_player_bot     decides      -- never acts
    pw_bot_runtime    acts         -- through a real Luanti client

This package launches an actual Luanti client on an isolated X display, claims
intents the brain published, and carries them out with keyboard and pointer
input — the same channel a human uses and the only one it has. It does not
teleport, does not set velocity, does not open a door from the server side, and
does not write a node. If the bot got somewhere, it walked.

Its knowledge of the world comes from ``pw_bot_bridge`` and nowhere else. It
takes screenshots for people to look at and never reads one back.
"""

from .config import Config, load_config, redact
from .errors import (BridgeRefused, BridgeUnavailable, ClientError, ConfigError,
                     DependencyMissing, DisplayError, IntentInvalid, OperatorStopped,
                     RuntimeError_, WindowNotFound)

__version__ = "0.1.0"
PROTOCOL = "pw_bot_runtime/v1"

#: Protocols this runtime speaks to. Both are consumed, neither is extended
#: here: the runtime is a client of the server's contracts, not a co-author.
CONSUMES = ("pw_bot_bridge/v1", "pw_player_bot/v1")

__all__ = [
    "Config", "load_config", "redact", "ConfigError", "DependencyMissing",
    "DisplayError", "ClientError", "WindowNotFound", "BridgeUnavailable",
    "BridgeRefused", "IntentInvalid", "OperatorStopped", "RuntimeError_",
    "__version__", "PROTOCOL", "CONSUMES",
]
