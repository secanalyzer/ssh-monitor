#!/usr/bin/env python3
"""Manage an SSH SOCKS5 tunnel with auto-reconnect and systemd deployment.

Reproduces and supervises a command such as:

    ssh -J user@jumpbox:5522 \
        -i /home/user/.ssh/id_rsa \
        -o ServerAliveInterval=30 \
        -D 23456 -p 22 user@server1

The local SOCKS5 proxy is exposed on 127.0.0.1:<socks-port>.

Alternatively, any ssh command can be supervised verbatim by appending it after
the options (use `--` to separate it):

    ssh_monitor.py run -- ssh -N -L 8080:127.0.0.1:80 user@server1

With --once the command is executed a single time and its exit status is
returned instead of restarting it — for short-lived commands.

Subcommands:
    run         Run the supervised tunnel in the foreground (default).
    install     Install + enable + start a systemd service for the tunnel.
    uninstall   Stop + disable + remove the systemd service.
    status      Show `systemctl status` for the service.
    print-unit  Print the generated systemd unit file to stdout.
"""

from __future__ import annotations

import argparse
import os
import shlex
import signal
import socket
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Defaults (match the reference command)
# ---------------------------------------------------------------------------
DEF_USER = "user"
DEF_JUMP_HOST = "jumpbox"
DEF_JUMP_PORT = 5522
DEF_REMOTE_HOST = "server1"
DEF_REMOTE_SSH_PORT = 22
DEF_KEY = "/home/user/.ssh/id_rsa"
DEF_SOCKS_PORT = 23456
DEF_SERVER_ALIVE_INTERVAL = 30
DEF_MAX_RETRIES = 10
DEF_STABLE_AFTER = 60          # seconds up => treat as a healthy session, reset retry budget
DEF_BACKOFF_BASE = 5           # seconds
DEF_BACKOFF_CAP = 60           # seconds
DEF_SERVICE_NAME = "ssh-monitor"


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# ssh command construction
# ---------------------------------------------------------------------------
def build_ssh_command(a: argparse.Namespace) -> list[str]:
    # A user-provided command is supervised verbatim: no built-in flags are
    # added, so the user keeps full control over what ssh actually does.
    if a.ssh_cmd:
        return list(a.ssh_cmd)

    cmd: list[str] = ["ssh", "-N"]  # -N: no remote command, tunnel only

    if a.key:
        cmd += ["-i", a.key]

    # Dynamic SOCKS5 forward on the local side.
    cmd += ["-D", str(a.socks_port)]

    # JumpProxy only when -J/--jump is requested. The jump host may use its own
    # login user (--jump-user); it falls back to the target's --user.
    if a.jump:
        jump_user = a.jump_user or a.user
        cmd += ["-J", f"{jump_user}@{a.jump_host}:{a.jump_port}"]

    # Optional ssh config file. Unlike -o options, an -F config DOES propagate to
    # the ProxyJump (-J) inner connection, so it is the way to configure host-key
    # handling / identities for the *jump* host non-interactively.
    if a.ssh_config:
        cmd += ["-F", a.ssh_config]

    # Robustness / service-friendly defaults. ssh uses the FIRST value it sees for
    # a given option, so a user --ssh-option can only win if we DROP the built-in
    # default for that key. We therefore emit only the defaults the user did not
    # override, then the user's options.
    user_opts = a.ssh_option or []
    user_keys = {o.split("=", 1)[0].strip().lower() for o in user_opts}
    defaults = [
        ("ServerAliveInterval", str(a.server_alive_interval)),
        ("ServerAliveCountMax", "3"),
        ("ExitOnForwardFailure", "yes"),
        ("StrictHostKeyChecking", "accept-new"),
        ("BatchMode", "yes"),
    ]
    for key, val in defaults:
        if key.lower() not in user_keys:
            cmd += ["-o", f"{key}={val}"]
    for opt in user_opts:
        cmd += ["-o", opt]

    # Remote SSH port + destination.
    cmd += ["-p", str(a.remote_ssh_port), f"{a.user}@{a.remote_host}"]
    return cmd


# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------
class Supervisor:
    def __init__(self, args: argparse.Namespace):
        self.a = args
        self.stop = False
        self._signum: int | None = None
        self.proc: subprocess.Popen | None = None

    def _handle_signal(self, signum, _frame):
        # Keep this minimal and lock-free: just record intent. Tearing down the
        # child here would deadlock/spin, because the main thread already holds
        # subprocess's internal waitpid lock while blocked in proc.wait(). The
        # main loop performs the actual teardown once it observes self.stop.
        self._signum = signum
        self.stop = True

    def _terminate_child(self) -> None:
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return
        try:
            # Kill the whole process group (start_new_session=True below).
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=10)
            return
        except subprocess.TimeoutExpired:
            log("ssh did not exit after SIGTERM; sending SIGKILL")
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    def _port_free(self) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("127.0.0.1", self.a.socks_port))
                return True
            except OSError:
                return False

    def _sleep(self, seconds: float) -> None:
        """Sleep that wakes up promptly when a stop signal arrives."""
        deadline = time.monotonic() + seconds
        while not self.stop and time.monotonic() < deadline:
            time.sleep(min(0.5, deadline - time.monotonic()))

    def _run_ssh_session(self) -> tuple[int, float]:
        """Launch ssh and block until it exits, or until a stop signal arrives —
        in which case the child is torn down from this (the main) thread. Returns
        (exit_rc, uptime_seconds). Raises FileNotFoundError if `ssh` is missing."""
        cmd = build_ssh_command(self.a)
        log("starting: " + " ".join(shlex.quote(c) for c in cmd))
        start = time.monotonic()
        self.proc = subprocess.Popen(cmd, start_new_session=True)

        # Poll instead of blocking indefinitely so a stop signal is noticed
        # promptly (see _handle_signal for why teardown must happen here).
        rc = None
        while rc is None:
            try:
                rc = self.proc.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                if self.stop:
                    name = signal.Signals(self._signum).name if self._signum else "stop"
                    log(f"received {name}; shutting down ssh")
                    self._terminate_child()
                    rc = self.proc.poll()
                    if rc is None:
                        rc = self.proc.wait()
        return rc, time.monotonic() - start

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

        a = self.a
        retries = 0
        if a.ssh_cmd:
            log(f"supervising user-provided command "
                f"(mode={'once' if a.once else 'monitor'}, max_retries={a.max_retries})")
        else:
            log(f"SOCKS5 proxy target: 127.0.0.1:{a.socks_port} "
                f"(jump={'on' if a.jump else 'off'}, max_retries={a.max_retries})")

        while not self.stop:
            # The SOCKS port is only known for the built-in tunnel command; a
            # user-provided command may bind anything (or nothing).
            if not a.ssh_cmd and not self._port_free():
                log(f"WARNING: local SOCKS port {a.socks_port} is not bindable; "
                    f"another process may be using it")

            try:
                rc, uptime = self._run_ssh_session()
            except FileNotFoundError:
                log(f"ERROR: `{build_ssh_command(a)[0]}` not found on PATH")
                return 2

            if self.stop:
                break

            if a.once:
                log(f"ssh exited rc={rc} after {uptime:.0f}s (--once: not restarting)")
                # Negative rc means killed-by-signal; map to the shell convention.
                return rc if rc >= 0 else 128 - rc

            # A session that stayed up long enough is considered healthy:
            # reset the retry budget so long-lived tunnels can drop-and-recover
            # indefinitely.
            if uptime >= a.stable_after:
                if retries:
                    log(f"connection was stable for {uptime:.0f}s; resetting retry counter")
                retries = 0

            retries += 1
            log(f"ssh exited rc={rc} after {uptime:.0f}s "
                f"(failure {retries}"
                f"{'/' + str(a.max_retries) if a.max_retries >= 0 else ''})")

            if a.max_retries >= 0 and retries > a.max_retries:
                log(f"exhausted {a.max_retries} retries; giving up")
                return 3

            backoff = min(a.backoff_cap, a.backoff_base * (2 ** (retries - 1)))
            log(f"reconnecting in {backoff:.0f}s")
            self._sleep(backoff)

        log("stopped cleanly")
        return 0


# ---------------------------------------------------------------------------
# systemd integration
# ---------------------------------------------------------------------------
def reconstruct_run_args(a: argparse.Namespace) -> list[str]:
    """Rebuild an explicit `run ...` argv that reproduces this config.

    Driven by CONN_PARAMS (see the CLI section) so it can never fall out of sync
    with the parser — every connection flag is round-tripped with its resolved
    value, which is what bakes an explicit, self-contained command into the unit.
    """
    out = ["run"]
    for flag, _kw in CONN_PARAMS:
        dest = flag.lstrip("-").replace("-", "_")
        out += [flag, str(getattr(a, dest))]
    if a.jump:
        out.append("--jump")
    if a.jump_user:
        out += ["--jump-user", a.jump_user]
    if a.ssh_config:
        out += ["--ssh-config", a.ssh_config]
    for opt in a.ssh_option or []:
        out += ["--ssh-option", opt]
    if a.once:
        out.append("--once")
    if a.ssh_cmd:
        out += ["--", *a.ssh_cmd]
    return out


def build_unit(a: argparse.Namespace, user_scope: bool) -> str:
    script = os.path.realpath(sys.argv[0])
    py = os.path.realpath(sys.executable)
    run_args = reconstruct_run_args(a)
    exec_start = " ".join(shlex.quote(x) for x in [py, script, *run_args])
    wanted_by = "default.target" if user_scope else "multi-user.target"
    if a.ssh_cmd:
        desc = "Supervised ssh command (" + " ".join(a.ssh_cmd) + ")"
    else:
        desc = f"SSH SOCKS5 tunnel ({a.remote_host} -> 127.0.0.1:{a.socks_port})"
    # In --once mode the command must run exactly once: no supervisor restart,
    # and no systemd restart either.
    restart = "no" if a.once else "on-failure"

    return f"""\
[Unit]
Description={desc}
After=network-online.target
Wants=network-online.target
# StartLimit* live in [Unit]. They cap systemd's own restart storms; the
# in-process --max-retries budget is the primary reconnect policy.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart={exec_start}
# The supervisor owns the reconnect policy (--max-retries). systemd Restart is an
# outer safety net for an unexpected supervisor crash ("no" in --once mode).
Restart={restart}
RestartSec=5
# Clean shutdown: the supervisor traps SIGTERM and tears down ssh; KillMode=mixed
# also reaps the whole cgroup as a backstop so no ssh survives a stop.
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy={wanted_by}
"""


def unit_paths(name: str, user_scope: bool) -> str:
    if user_scope:
        base = os.path.expanduser("~/.config/systemd/user")
    else:
        base = "/etc/systemd/system"
    return os.path.join(base, f"{name}.service")


def systemctl(user_scope: bool, *sctl_args: str) -> int:
    cmd = ["systemctl"] + (["--user"] if user_scope else []) + list(sctl_args)
    log("+ " + " ".join(shlex.quote(c) for c in cmd))
    return subprocess.call(cmd)


def cmd_install(a: argparse.Namespace) -> int:
    unit = build_unit(a, a.user_scope)
    path = unit_paths(a.service_name, a.user_scope)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(unit)
    log(f"wrote unit: {path}")
    systemctl(a.user_scope, "daemon-reload")
    systemctl(a.user_scope, "enable", a.service_name)
    rc = systemctl(a.user_scope, "restart", a.service_name)
    scope = "--user" if a.user_scope else "(system)"
    log(f"installed. Inspect with: systemctl {scope} status {a.service_name}")
    return rc


def cmd_uninstall(a: argparse.Namespace) -> int:
    systemctl(a.user_scope, "stop", a.service_name)
    systemctl(a.user_scope, "disable", a.service_name)
    path = unit_paths(a.service_name, a.user_scope)
    if os.path.exists(path):
        os.remove(path)
        log(f"removed unit: {path}")
    systemctl(a.user_scope, "daemon-reload")
    return 0


def cmd_status(a: argparse.Namespace) -> int:
    return systemctl(a.user_scope, "status", a.service_name)


def cmd_print_unit(a: argparse.Namespace) -> int:
    sys.stdout.write(build_unit(a, a.user_scope))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
# The connection value-args, declared ONCE: this table drives both the CLI parser
# (add_connection_args) and the systemd-unit reconstruction (reconstruct_run_args),
# so a new option can never be added to one and forgotten in the other. The "(default:
# ...)" help suffix is appended automatically. The non-uniform args
# (-J/--jump store_true, --jump-user with its --user fallback, -o/--ssh-option
# append, -F/--ssh-config) are declared explicitly below.
CONN_PARAMS = [
    ("--user", dict(default=DEF_USER, help="login user")),
    ("--jump-host", dict(default=DEF_JUMP_HOST, help="jump host")),
    ("--jump-port", dict(type=int, default=DEF_JUMP_PORT, help="jump port")),
    ("--remote-host", dict(default=DEF_REMOTE_HOST, help="remote host")),
    ("--remote-ssh-port", dict(type=int, default=DEF_REMOTE_SSH_PORT, help="remote SSH port")),
    ("--key", dict(default=DEF_KEY, help="private key file")),
    ("--socks-port", dict(type=int, default=DEF_SOCKS_PORT, help="local SOCKS5 proxy port")),
    ("--server-alive-interval", dict(type=int, default=DEF_SERVER_ALIVE_INTERVAL,
                                     help="ServerAliveInterval seconds")),
    ("--max-retries", dict(type=int, default=DEF_MAX_RETRIES,
                           help="max consecutive reconnect attempts, -1 = unlimited")),
    ("--stable-after", dict(type=int, default=DEF_STABLE_AFTER,
                            help="seconds up before a session is deemed healthy and the "
                                 "retry counter resets")),
    ("--backoff-base", dict(type=int, default=DEF_BACKOFF_BASE, help="base reconnect backoff seconds")),
    ("--backoff-cap", dict(type=int, default=DEF_BACKOFF_CAP, help="max reconnect backoff seconds")),
]


def add_connection_args(p: argparse.ArgumentParser) -> None:
    for flag, kw in CONN_PARAMS:
        kw = dict(kw)
        kw["help"] = f"{kw['help']} (default: {kw['default']})"
        p.add_argument(flag, **kw)
    p.add_argument("-J", "--jump", action="store_true",
                   help="use the SSH JumpProxy (-J) setting; omit to connect directly")
    p.add_argument("--jump-user", default=None, metavar="USER",
                   help="login user on the jump host (default: same as --user)")
    p.add_argument("-o", "--ssh-option", action="append", metavar="KEY=VALUE",
                   help="extra ssh -o option (repeatable); overrides built-in defaults")
    p.add_argument("-F", "--ssh-config", default=None, metavar="FILE",
                   help="ssh config file (-F); unlike -o, this also configures the -J jump host")
    p.add_argument("--once", action="store_true",
                   help="short-lived mode: run the ssh command exactly once and exit with "
                        "its status instead of restarting it when it finishes")
    p.add_argument("ssh_cmd", nargs=argparse.REMAINDER, metavar="[--] COMMAND [ARG ...]",
                   help="supervise this ssh command verbatim instead of the built-in tunnel "
                        "command (everything after the options, or after `--`, is taken as-is)")


def add_service_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--service-name", default=DEF_SERVICE_NAME,
                   help=f"systemd service name (default: {DEF_SERVICE_NAME})")
    p.add_argument("--user-scope", action="store_true",
                   help="use a per-user systemd service (systemctl --user) instead of system-wide")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command")

    pr = sub.add_parser("run", help="run the supervised tunnel (foreground)")
    add_connection_args(pr)
    pr.add_argument("--dry-run", action="store_true", help="print the ssh command and exit")
    pr.set_defaults(func=_cmd_run)

    for name, fn, helptext in [
        ("install", cmd_install, "install + enable + start the systemd service"),
        ("uninstall", cmd_uninstall, "stop + disable + remove the systemd service"),
        ("status", cmd_status, "show systemctl status for the service"),
        ("print-unit", cmd_print_unit, "print the generated systemd unit file"),
    ]:
        sp = sub.add_parser(name, help=helptext)
        add_connection_args(sp)
        add_service_args(sp)
        sp.set_defaults(func=fn)

    return p


def _cmd_run(a: argparse.Namespace) -> int:
    if a.dry_run:
        print(" ".join(shlex.quote(c) for c in build_ssh_command(a)))
        return 0
    return Supervisor(a).run()


def main(argv: list[str]) -> int:
    # Default to the `run` subcommand when none is given.
    known = {"run", "install", "uninstall", "status", "print-unit", "-h", "--help"}
    if not argv or argv[0] not in known:
        argv = ["run"] + argv

    parser = build_parser()
    a = parser.parse_args(argv)
    # argparse keeps the `--` separator inside a REMAINDER capture; drop it so
    # ssh_cmd holds the bare command argv.
    if getattr(a, "ssh_cmd", None) and a.ssh_cmd[0] == "--":
        a.ssh_cmd = a.ssh_cmd[1:]
    if not getattr(a, "command", None):
        parser.print_help()
        return 1
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
