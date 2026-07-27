# PW Bot

PW Bot is the planned automated inhabitant of PerfectWorld: a program that
connects to the server as an ordinary player, looks around, and walks. It does
not exist yet.

What exists today is its first half — **`pw_bot_bridge`**, the server mod that
gives such a program senses.

```
Bridge observes and explains.
The real client acts.
```

## Documents

| Document | Covers |
|----------|--------|
| [architecture.md](architecture.md) | Why the bridge lives inside PerfectWorld, and how the pieces fit |
| [bridge-api.md](bridge-api.md) | The internal Lua API a future `pw_bot` may depend on |
| [protocol-v1.md](protocol-v1.md) | `pw_bot_bridge/v1`: envelopes, operations, error codes, determinism |
| [player-perception.md](player-perception.md) | What `player` mode reports, and the exact contract behind it |
| [oracle-perception.md](oracle-perception.md) | What `oracle` mode reports, and what it is for |
| [semantics.md](semantics.md) | The central semantic registry and normalised node properties |
| [security.md](security.md) | Privileges, mode assignment, the transport, and what is not defended |
| [testing.md](testing.md) | Scenes, unit tests, integration tests, how to run them |
| [limitations.md](limitations.md) | Everything the bridge cannot do, stated plainly |

## Status

| Component | State |
|-----------|-------|
| `pw_bot_bridge` server mod | implemented, tested, documented |
| `pw_bot_bridge/v1` protocol | implemented |
| External file transport | implemented, **off by default** |
| PW Bot itself | **not implemented** |
| Client control, movement, navigation, memory, behaviour | **not implemented** |

Nothing in this directory should be read as a claim that PW Bot exists. It
describes the interface the bot will be built on.

## The one-paragraph version

`pw_bot_bridge` watches a connected, ordinary player and answers structured
questions about what that player could know. In `player` mode the answers are
bounded by position, look direction, field of view, view distance and line of
sight — a deterministic server-side approximation of a player's programmatic
perception, not a copy of their screen. In `oracle` mode the same read-only
machinery answers exactly, within configured limits, so the test kit and a
coding agent can find physical defects in generated villages. Neither mode ever
acts: the bridge does not move the player, turn their head, open a door, or
decide anything.

## Perception is not a screenshot

A screenshot is not the bot's vision and never will be. The bridge reads the
server's own world state. Screenshots remain what they are in this project
today: a diagnostic artifact produced for a human to look at.

## Reading order

Start with [architecture.md](architecture.md) for the shape of the thing, then
[player-perception.md](player-perception.md) for the contract that matters most,
then [protocol-v1.md](protocol-v1.md) when you are ready to send a request.
