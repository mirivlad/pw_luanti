# PW Bot

PW Bot is the planned automated inhabitant of PerfectWorld: a program that
connects to the server as an ordinary player, looks around, and walks.

All three of its parts exist:

```
pw_bot_bridge     perceives    -- never acts
pw_player_bot     decides      -- never acts
pw_bot_runtime    acts         -- a hand on a keyboard, nothing else
```

The bridge answers structured questions about what a connected player could
know. The brain reads those answers, remembers them, and writes down what it has
decided to do. The runtime reads that decision and presses the keys, in a real
client, on a display it created — and then asks the bridge whether the world
actually changed.

What is missing is not a part but a *purpose*: the brain's goals are explore,
approach, retreat, leave liquid, look, unstick and stand still. None of them
goes somewhere in order to do something. `interact` is in the intent vocabulary
and the runtime executes it; no goal emits it.

## Documents

### The bridge — senses

| Document | Covers |
|----------|--------|
| [architecture.md](architecture.md) | Why the bridge lives inside PerfectWorld, and how the pieces fit |
| [bridge-api.md](bridge-api.md) | The internal Lua API a consumer may depend on |
| [protocol-v1.md](protocol-v1.md) | `pw_bot_bridge/v1`: envelopes, operations, error codes, determinism |
| [player-perception.md](player-perception.md) | What `player` mode reports, and the exact contract behind it |
| [oracle-perception.md](oracle-perception.md) | What `oracle` mode reports, and what it is for |
| [semantics.md](semantics.md) | The central semantic registry and normalised node properties |
| [security.md](security.md) | Privileges, mode assignment, the transport, and what is not defended |

### The brain — decisions

| Document | Covers |
|----------|--------|
| [player-bot.md](player-bot.md) | The decision loop, modules, settings, commands |
| [player-bot-memory.md](player-bot-memory.md) | Bounded memory, confidence, staleness, beliefs, the frontier |
| [player-bot-decisions.md](player-bot-decisions.md) | Needs, the fear gate, goals, utility scoring, tie-breaks |
| [intent-v1.md](intent-v1.md) | `pw_player_bot/v1`: the document a controller executes |

### Both

| Document | Covers |
|----------|--------|
| [testing.md](testing.md) | Scenes, unit tests, integration tests, how to run them |
| [limitations.md](limitations.md) | Everything neither mod can do, stated plainly |

## Status

| Component | State |
|-----------|-------|
| `pw_bot_bridge` server mod | implemented, tested, documented |
| `pw_bot_bridge/v1` protocol | implemented |
| External file transport | implemented, **off by default** |
| `pw_player_bot` brain | implemented, tested, documented |
| `pw_player_bot/v1` intent protocol | implemented |
| `pw_bot_runtime` — the body that executes an intent | implemented, measured against the obstacle course |
| Movement: walking, turning, kerbs, stairs | works |
| Interaction: doors, fence gates, trapdoors | works, by hand, through a real client |
| Errands — a goal that goes somewhere *in order to do something* | **not implemented** |
| Building, NPCs, LLM integration | **not implemented** |

Nothing in this directory should be read as a claim that PW Bot walks. It
decides, in writing, and stops.

## The one-paragraph version — the brain

`pw_player_bot` asks the bridge, in player mode only, what its player can
perceive; folds the answer into a bounded memory with a confidence per fact;
derives beliefs about what is walkable and where the edge of its knowledge is;
turns its condition into five drives; scores every goal those beliefs make
possible; plans a route across remembered columns only; and writes an intent
document saying what a controller should do. It never moves, turns, interacts,
reads the map, or uses oracle data — and it never calls `math.random`, so the
same memory and the same observation always produce the same intent.

## The one-paragraph version — the bridge

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
