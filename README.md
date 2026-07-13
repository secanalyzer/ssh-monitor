# ssh_monitor

Supervises an SSH dynamic (SOCKS5) tunnel with auto-reconnect and ships it as a
systemd service. Pure Python 3 stdlib, no dependencies, no `autossh` needed.

Reproduces:

```bash
ssh -J user@jumpbox:5522 -i /home/user/.ssh/id_ed25519 -o ServerAliveInterval=30 \
    -D 23456 -p 22 user@server1
```

The local SOCKS5 proxy is exposed on `127.0.0.1:<socks-port>`.

## Parameters (defaults match the reference command)

| Flag | Default | Meaning |
|------|---------|---------|
| `--user` | `user` | login user |
| `--jump-host` | `jumpbox` | jump host |
| `--jump-port` | `5522` | jump port |
| `--jump-user` | same as `--user` | login user on the jump host, when it differs from the target's |
| `--remote-host` | `server1` | remote host |
| `--remote-ssh-port` | `22` | remote SSH port |
| `--key` | `/home/user/.ssh/id_ed25519` | private key file |
| `--socks-port` | `23456` | local SOCKS5 proxy port |
| `-J`, `--jump` | off | use the JumpProxy (`ssh -J`); omit to connect **directly** |
| `-o`, `--ssh-option KEY=VALUE` | – | extra `ssh -o` option (repeatable; overrides built-in defaults) |
| `-F`, `--ssh-config FILE` | – | ssh config file (`-F`); unlike `-o`, this **also** configures the `-J` jump host |
| `--server-alive-interval` | `30` | `ServerAliveInterval` seconds |
| `--max-retries` | `10` | max consecutive reconnect attempts; `-1` = unlimited |
| `--stable-after` | `60` | seconds up before a session is deemed healthy and the retry budget resets |
| `--backoff-base` / `--backoff-cap` | `5` / `60` | exponential reconnect backoff bounds (seconds) |
| `--once` | off | short-lived mode: run the ssh command exactly once, exit with its status, never restart |
| `[--] COMMAND ...` | – | supervise this ssh command **verbatim** instead of the built-in tunnel command |

Built-in ssh options (all overridable via `-o`): `ServerAliveCountMax=3`,
`ExitOnForwardFailure=yes`, `StrictHostKeyChecking=accept-new`, `BatchMode=yes`.
A `--ssh-option` overriding one of these wins (ssh takes the *first* value for an
option, so the matching built-in default is dropped when you override it).

### Jump-host trust (`-J`) caveat

`-o` options apply only to the **final** hop — OpenSSH's `-J` runs the jump-host
connection in a separate inner ssh that reads `~/.ssh/config` only. So the jump
host's key/identity cannot be configured with `-o`; the jump host must already be
in `~/.ssh/known_hosts` (normal once you've connected once), or point at a config
with `-F FILE` (which **does** propagate to the jump hop). For an unattended
service, connect once interactively first so the jump host key is trusted.

For example, use the `~/.ssh/config-jumpid` file to pass data to the `-J` command:
```
GSSAPIAuthentication No
GSSAPIKeyExchange No
TCPKeepAlive    Yes
ForwardX11      Yes
ServerAliveInterval 59
GatewayPorts    Yes
USER alice
IdentityFile /home/alice/.ssh/id_ed25519
```

## Run in the foreground

```bash
# direct connection, default port
./ssh_monitor.py run

# via jump host, on an alternate port
./ssh_monitor.py run -J --socks-port 3335

# preview the exact ssh command without running it
./ssh_monitor.py run -J --socks-port 23459 --dry-run
```

`run` is the default, so `./ssh_monitor.py -J --socks-port 3335` also works.

## Supervise an arbitrary ssh command

Append any ssh command after the options (a `--` separator keeps its flags out
of the option parser). It is run **verbatim** — none of the built-in tunnel
flags or `-o` defaults are added — and monitored with the same
reconnect/backoff/retry policy:

```bash
# monitor + auto-restart a port-forward command
./ssh_monitor.py run --max-retries -1 -- ssh -N -L 8080:127.0.0.1:80 user@server1

# short-lived command: run it ONCE, exit with its status, never restart
./ssh_monitor.py run --once -- ssh user@server1 uptime
```

* Without `--once`, the command is supervised exactly like the built-in tunnel
  (backoff, retry budget, stable-session reset, clean SIGTERM teardown).
* With `--once`, the command runs a single time and the supervisor exits with
  the command's status (`128+N` if it died on signal N); SIGTERM still tears it
  down cleanly with exit `0`.
* Both work with `install`/`print-unit`: the command and `--once` are baked
  into the unit's `ExecStart`, and a `--once` unit gets `Restart=no`.
* The connection flags (`--user`, `--socks-port`, …) only shape the built-in
  command; they are ignored when a custom command is given. The supervisor
  flags (`--max-retries`, `--stable-after`, `--backoff-*`) still apply.

### Reconnect behaviour

* ssh runs with `ServerAliveInterval`/`ServerAliveCountMax` so a dead peer is
  detected and ssh exits; the supervisor then reconnects.
* Each drop increments a counter; after `--max-retries` **consecutive** failures
  the supervisor exits non-zero (code `3`).
* A session that stays up ≥ `--stable-after` seconds is treated as healthy and
  **resets** the counter, so a long-lived tunnel can drop-and-recover forever.
* Backoff between attempts is exponential, capped at `--backoff-cap`.
* `SIGTERM`/`SIGINT` tears down ssh cleanly (process-group kill) and exits `0`.

## Deploy as a systemd service

System-wide (needs root; `WantedBy=multi-user.target`):

```bash
sudo ./ssh_monitor.py install -J --socks-port 23456
sudo ./ssh_monitor.py status
sudo ./ssh_monitor.py uninstall
```

Per-user (no root; `systemctl --user`, `WantedBy=default.target`):

```bash
./ssh_monitor.py install --user-scope -J --socks-port 3335
systemctl --user status ssh-monitor
# survive logout:  loginctl enable-linger "$USER"
./ssh_monitor.py uninstall --user-scope
```

`install` writes the unit, `daemon-reload`s, `enable`s (auto-start on boot) and
`restart`s it. All connection flags are baked into the unit's `ExecStart`.
Use `--service-name NAME` to run several tunnels side by side. Preview the unit
without installing via `print-unit`.

### Service semantics

* **Auto-start:** enabled + `After/Wants=network-online.target`.
* **Clean stop:** the supervisor traps `SIGTERM`; `KillMode=mixed` reaps the
  whole cgroup as a backstop, so **no ssh survives** `systemctl stop`.
* **Restart policy:** the in-process `--max-retries` budget is the primary
  reconnect policy. `Restart=on-failure` + `StartLimitIntervalSec=300` /
  `StartLimitBurst=5` are an outer safety net that caps supervisor crash loops.

## Comparison with autossh

`autossh` solves the same core problem — restart ssh when the connection dies —
but the two differ in approach and scope (autossh facts per `autossh(1)`, v1.4g):

| | ssh_monitor | autossh |
|---|---|---|
| Failure detection | ssh's own keepalives (`ServerAliveInterval`/`CountMax` make ssh exit on a dead peer); supervisor restarts on abnormal exit | active probe: echo test data through a monitor port or a loop of forwardings (`-M`) |
| Restart policy | `--max-retries` budget (`-1` = infinite), exponential backoff (`--backoff-base`/`--backoff-cap`), `--stable-after` resets the budget | unlimited restarts; tuned via env vars (`AUTOSSH_GATETIME`, `AUTOSSH_POLL`, …) |
| systemd | generates and manages its own units: `install` / `uninstall` / `status` / `print-unit`, `--user-scope`, `--service-name` for parallel tunnels | bring your own unit file |
| Scope | any ssh command (`run -- ssh …`), plus `--once` for short-lived commands | tunnel keeper only |
| Jump hosts | first-class: `--jump`, `--jump-user`, `--jump-port`, `--ssh-config` | pass raw `-J` yourself |
| Implementation | single-file Python 3 stdlib, with a test suite | C binary from a package |

Where ssh_monitor is the better fit:

* **No extra ports, nothing on the remote.** autossh's monitor loop needs a
  spare port pair (or a remote echo service) and can false-restart under
  congestion. Keepalive-based detection uses the ssh connection itself.
* **A real reconnect policy.** Bounded retry budget, exponential backoff, and
  stability-based budget reset are explicit flags — not env-var tuning around
  an always-restart loop — so a flapping link degrades predictably and
  exhaustion is a visible exit code (`3`).
* **Self-deploying.** One command installs a correct unit (clean `SIGTERM`
  teardown, `KillMode=mixed` backstop, user-scope support); no hand-written
  service files to keep in sync.
* **Broader than tunnels.** The same supervision applies to any ssh command,
  and `--once` covers run-to-completion jobs.
* **Hackable and testable.** Plain stdlib Python with tests beats patching and
  rebuilding C when behavior needs to change.

Pick autossh instead if you specifically want active in-band traffic probing —
detecting a link that is up but silently dropping data — with zero runtime
dependencies beyond the binary.

## Verified

Tested end-to-end against a throwaway `sshd` on `127.0.0.1` (localhost standing in
for the remote, plus a second sshd as a distinct jump host), on alternate ports
`3335` / `23459`:

* **Direct mode** — real `ssh -D`, live HTTP fetched *through* the SOCKS5 proxy.
* **`-J` jump mode** — two-hop tunnel (`localhost:2223` → `localhost:2222`), data
  fetched through the proxy; jump sshd logged the accepted login.
* **Auto-reconnect** — killed the live ssh child; supervisor detected the drop,
  reconnected (new pid), and a second fetch succeeded through the fresh tunnel.
* **Retry policy** — exhaustion exits `3`; a session up ≥ `--stable-after` resets
  the budget so it never falsely exhausts.
* **systemd** — a real `--user` service reached `active`, served proxied traffic,
  and on `stop` closed the SOCKS port with no orphaned ssh; clean uninstall.
* **Clean shutdown** — `SIGTERM` tears down ssh in well under a second.
