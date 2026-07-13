# Tests

Self-contained test suite for `ssh_monitor.py`. Every test that needs a
network stands up a **throwaway `sshd` on `127.0.0.1`** (and a second one as a
jump host) plus a local HTTP "origin" behind the tunnel, using disposable keys in
a `mktemp` dir. Nothing touches the system sshd, the user's real `~/.ssh`, or the
internet; all background processes run at `nice -n 19` and are torn down on exit.

## Run

```bash
bash tests/run_all.sh              # full suite
bash tests/run_all.sh test_tunnel  # subset (name glob)
```

Prints per-test `PASS`/`FAIL` lines and a final `TOTAL: N passed, M failed`.
Exit code is non-zero if anything failed.

**Requires:** `python3`, `ssh`, `sshd` (`/usr/sbin/sshd`), `ssh-keygen`, `curl`,
`ss`. The systemd test self-skips if `systemctl --user` is unavailable.

## What each test covers

| File | Network? | Checks |
|------|----------|--------|
| `test_cmd.sh` | no | ssh command construction: defaults match the reference command, `-J` toggle, alternate ports/params, `-o` overriding a built-in default (ssh first-value-wins), `-F` flag |
| `test_retry.sh` | no (fake `ssh`) | exhaustion after `--max-retries` → exit `3`; a session up ≥ `--stable-after` resets the budget so it never falsely exhausts |
| `test_shutdown.sh` | no (fake `ssh`) | `SIGTERM` → exit `0` in < 3s, no orphaned child, no forced SIGKILL |
| `test_tunnel_direct.sh` | yes | real `ssh -D` to localhost sshd; HTTP fetched through the SOCKS5 proxy |
| `test_tunnel_jump.sh` | yes | real 2-hop `-J` tunnel (`:2223` → `:2222`) via `-F`; jump sshd logs the accepted login |
| `test_reconnect.sh` | yes | kill the live ssh child → supervisor reconnects (new pid) → fetch works again |
| `test_systemd.sh` | yes | real `--user` service: `active` + `enabled`, fetch through it, `stop` closes the port with no orphan, clean `uninstall` |

## Notes / gotchas encoded here

- **`pkill -f`/`pgrep -f` patterns are bracketed** (e.g. `-D 3335[^0-9]`) so a
  pattern can never match the harness's own command line — a real footgun that
  otherwise makes a cleanup line kill its own shell.
- **A `-J` jump host must differ from the target**, or OpenSSH rejects the hop as
  a loop — hence two sshd instances on different ports.
- **`-o` options do not reach the `-J` jump hop** (it's a separate inner ssh that
  reads config only); the jump test configures both hops via `-F ssh_config`.
- Port overrides: `SSHD_PORT`, `JUMP_PORT`, `ORIGIN_PORT`, `SOCKS_PORT`,
  `SOCKS_PORT2` (env vars) if the defaults collide on your box.
