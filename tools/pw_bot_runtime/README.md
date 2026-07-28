# pw_bot_runtime

The body. It reads `pw_player_bot/v1` intents and performs them in a real Luanti
client, through real keyboard and pointer input, on a display it created itself.

There is no `set_pos`, no velocity, no server-side door and no node write. The
runtime is a hand on a keyboard and has no other way to affect anything. Its
knowledge of the world comes from `pw_bot_bridge` and nowhere else, and while it
takes screenshots for people to look at, it never reads one back.

```
pw_bot_bridge     perceives    -- never acts
pw_player_bot     decides      -- never acts
pw_bot_runtime    acts         -- this
```

## Running it

```bash
python3 -m pw_bot_runtime doctor --config runtime/pwbot.toml   # is the environment ready
python3 -m pw_bot_runtime run    --config runtime/pwbot.toml   # closed loop with the brain
python3 -m pw_bot_runtime scenario course                      # the acceptance course
```

`scenario` is a harness, not the bot deciding: it writes intents by hand and
sends them through the same executor, so an acceptance run can say "walk there,
then open that door" and get an honest answer about whether a real client could.
Build the course first with `scripts/pw-bot-course.sh build`.

From another terminal, while a run is going:

```bash
python3 -m pw_bot_runtime pause  --run-id <id>
python3 -m pw_bot_runtime resume --run-id <id>
python3 -m pw_bot_runtime stop   --run-id <id>
```

## Dependencies

None are required. `tomllib` is standard library from 3.11, and the input layer
falls back to `xdotool` — a binary, not a package — when `python-xlib` is
absent. A runtime that needs a virtualenv before it can be checked is a runtime
nobody checks, and `doctor` has to run on a bare server.

`python-xlib` (`python3-xlib` on Debian) is preferred: one X connection for the
whole run instead of a subprocess per keystroke.

## What it is careful about

* **Passwords.** The config holds a *path* to one, checks the file is `0600`,
  and reads the value once into an argument list on the way to
  `--password-file`. Everything bound for a log or an artifact goes through a
  redactor first.
* **The display.** It creates one rather than borrowing yours. The operator's
  own `$DISPLAY` is a third backend that stays off unless a human writes it
  down, because typing into a display that also has their editor on it is not a
  default anyone should get by accident.
* **The window.** It verifies that the window it is about to type into belongs
  to the client process it started.
* **Held keys.** Releasing them comes before everything else in teardown, on
  every path. A crash while holding W otherwise leaves a client walking into a
  wall until somebody notices.
* **Its own claims.** Every action is checked against the bridge afterwards. The
  runtime reports what it observed, not what it intended.

## Client configuration

`client.conf` pins the client's bindings instead of inheriting whatever the
operator last set. Two things in it are load-bearing and documented in the file
itself: place and dig are on keyboard keys rather than mouse buttons, and
`repeat_place_time` is pinned so that one hold is one action. Nothing in it
gives the bot an advantage — no noclip, no fly, no fast, no extra reach.

See [`docs/pw-bot/`](../../docs/pw-bot/README.md) for the protocol, the
perception contract and the limitations.
