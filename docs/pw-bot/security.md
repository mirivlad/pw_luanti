# Security

## The privilege

```
pw_bot_admin
```

Registered with `give_to_singleplayer = false`. Only a holder may register a
bot, remove a registration, change a mode, read administrative status, start the
external transport, or view oracle diagnostics about another player.

**Being able to type a chatcommand is not authorisation.** Every administrative
path re-checks the privilege against the acting player, whatever channel the
call arrived on. `registry.register`, `registry.set_mode`, `registry.set_limits`
and `transport.start` each check again, because "the caller already checked" is
not a property the code can see.

## Actors

An actor is one of exactly two things:

* a real player name, which must hold `pw_bot_admin`
* `pw_bot_bridge.SERVER_ACTOR` (`"@server"`), for a trusted server-side Lua
  caller: another PerfectWorld mod, or the test harness

There is no third option. A missing or empty actor is a refusal, not an implicit
grant. `"@server"` can never arrive from outside: the transport and the
chatcommands always substitute the real player name, and the registry rejects
`"@server"` as a player name.

## Why a bot cannot promote itself

Three independent barriers, in increasing order of strength:

1. `permissions.can_set_mode` refuses when the actor lacks the privilege, and
   names the case explicitly when the actor is the observed player itself
   (`self_escalation_denied`).
2. `registry.set_mode` re-checks rather than trusting its caller.
3. **There is no protocol operation that changes a mode, a registration or a
   privilege.** No request a bot could compose would reach the code in (1) at
   all. That is structural, not a check that could be forgotten.

The integration test proves this on a real server by stripping `pw_bot_admin`
from the connected `pwbot` — which the test harness normally grants everything —
then asserting that self-promotion, self-re-registration and a `set_mode`
request all fail, and that the mode did not move.

## Oracle is off unless granted

The default mode is `player`. Oracle is granted by the server: through
`pw_bot_bridge.autoregister`, by an administrator, or by the test harness. An
ordinary player who happens to be registered as a bot gets player mode and
nothing more.

Oracle diagnostics about another player require the privilege on the reader.
Oracle output describes the world, not the observer, so the check is on who is
asking.

## The external transport

**Off by default.** `pw_bot_bridge.external_transport` defaults to `false`, and
the spool directory is not even created until it is switched on.

It needs **no insecure environment**. The mod never calls
`request_insecure_environment()`, and `scripts/smoke-test.sh` fails the build if
anyone adds it. Everything it needs is inside the normal mod sandbox:
`minetest.mkdir`, `minetest.get_dir_list`, `minetest.safe_file_write`,
`io.open` and `os.remove` on paths inside the world directory. The mod probes
for each of them at startup and reports honestly through
`/pw_bot_bridge_transport status` if one is missing, rather than assuming.

Layout, inside the world directory:

```
<worldpath>/pw_bot_bridge/
├── requests/<player>/    written by the runtime, consumed by the bridge
├── responses/<player>/   written by the bridge, consumed by the runtime
├── events/<player>/      a refreshed, read-only mirror of the pending queue
├── state/                capability and status documents
└── rejected/             requests the bridge refused, with the reason
```

Writes go through `minetest.safe_file_write`, which writes a temporary file and
renames it, so a reader never sees a half-written document.

### Checked

| Attack | Defence |
|--------|---------|
| path traversal | every path component is validated; `/`, `\` and `..` are refused, and a rejected component yields no path at all rather than a risky one |
| writing outside the runtime directory | paths are only ever built by joining validated components to the spool root, which is asserted to be inside the world directory |
| forged player name | the player name comes from the directory the file was found in; a `player_name` field that disagrees is `permission_denied` |
| illegal file names | must match `^[A-Za-z0-9_.-]+\.json$`; anything else is never opened |
| request for an unregistered bot | `bot_not_registered`; only registered bots get directories |
| self-promotion to oracle | no such operation exists |
| oracle operation from player mode | `operation_not_allowed`, naming the mode |
| oversized request | the file size is checked before the parser sees it |
| malformed JSON | rejected, recorded, and parsed with the engine's error-returning mode so a junk spool cannot flood the server log with ERROR lines |
| duplicate request id | remembered per session; a replayed file is `invalid_request` |
| stale request | files surviving a restart are swept into `rejected/`, never executed |
| leaked stack traces | a Lua error is logged in full on the server and leaves as a bare `internal_error` |
| leaked filesystem paths | no response, chat message or error detail contains a server path; report commands print a file *name* only |
| uncontrolled mapblock loading | the map is read only through `get_node_or_nil`, which never generates |
| denial of service by scanning | per-bot token bucket, per-request node and time budgets, hard area ceilings, a cap on requests processed per transport tick |

### Not defended

**Symlinks inside the spool.** The Lua sandbox exposes no `lstat`, so the bridge
cannot tell a regular file from a symlink. Something that already has write
access to the world directory could plant one. That is an OS-level concern:
the world directory is server-owned and should not be writable by untrusted
accounts. The bridge reduces the surface — it never follows a path it did not
construct from validated components — but it cannot close this on its own, and
says so rather than implying otherwise.

**Anything running as the server user.** A process with the server's own
privileges can already do more than the transport allows. The spool is not a
privilege boundary against the local machine; it is an interface for a
cooperating local runtime.

## Response hygiene

* no Lua object references in any response — objects are named by opaque,
  session-scoped ids
* no server filesystem paths
* no stack traces
* error details carry scalars and short arrays only
* a response larger than the configured limit is replaced by a stated
  `response_too_large` error, never silently truncated

## Not in Git

The spool, runtime reports, world data and logs are all gitignored:

```
data/worlds/perfectworld/pw_bot_bridge/
data/worlds/perfectworld/pw_bot_bridge_*.json
```

No secret, password or credential is read, written or logged by this mod.
