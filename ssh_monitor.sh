#!/usr/bin/env bash
# Manage an SSH SOCKS5 tunnel with auto-reconnect and systemd deployment.
#
# Reproduces and supervises a command such as:
#
#     ssh -J user@jumpbox:5522 \
#         -i /home/user/.ssh/id_rsa \
#         -o ServerAliveInterval=30 \
#         -D 23456 -p 22 user@server1
#
# The local SOCKS5 proxy is exposed on 127.0.0.1:<socks-port>.
#
# Alternatively, any ssh command can be supervised verbatim by appending it
# after the options (use `--` to separate it):
#
#     ssh_monitor.sh run -- ssh -N -L 8080:127.0.0.1:80 user@server1
#
# With --once the command is executed a single time and its exit status is
# returned instead of restarting it — for short-lived commands.
#
# Subcommands:
#     run         Run the supervised tunnel in the foreground (default).
#     install     Install + enable + start a systemd service for the tunnel.
#     uninstall   Stop + disable + remove the systemd service.
#     status      Show `systemctl status` for the service.
#     print-unit  Print the generated systemd unit file to stdout.
#
# Pure bash + coreutils: no Python required on the server.

set -u

# ---------------------------------------------------------------------------
# Defaults (match the reference command)
# ---------------------------------------------------------------------------
# The connection value-args, declared ONCE: CONN_FLAGS drives the CLI parser,
# the help text, and the systemd-unit reconstruction, so a new option can
# never be added to one and forgotten in the other. The non-uniform args
# (-J/--jump, --jump-user, -o/--ssh-option, -F/--ssh-config, --once) are
# handled explicitly.
CONN_FLAGS=(--user --jump-host --jump-port --remote-host --remote-ssh-port
            --key --socks-port --server-alive-interval --max-retries
            --stable-after --backoff-base --backoff-cap)
declare -A CFG=(
    [--user]=user
    [--jump-host]=jumpbox
    [--jump-port]=5522
    [--remote-host]=server1
    [--remote-ssh-port]=22
    [--key]=/home/user/.ssh/id_rsa
    [--socks-port]=23456
    [--server-alive-interval]=30
    [--max-retries]=10
    [--stable-after]=60   # seconds up => healthy session, reset retry budget
    [--backoff-base]=5    # seconds
    [--backoff-cap]=60    # seconds
)
declare -A CONN_HELP=(
    [--user]="login user"
    [--jump-host]="jump host"
    [--jump-port]="jump port"
    [--remote-host]="remote host"
    [--remote-ssh-port]="remote SSH port"
    [--key]="private key file"
    [--socks-port]="local SOCKS5 proxy port"
    [--server-alive-interval]="ServerAliveInterval seconds"
    [--max-retries]="max consecutive reconnect attempts, -1 = unlimited"
    [--stable-after]="seconds up before a session is deemed healthy and the retry counter resets"
    [--backoff-base]="base reconnect backoff seconds"
    [--backoff-cap]="max reconnect backoff seconds"
)
declare -A INT_FLAGS=(
    [--jump-port]=1 [--remote-ssh-port]=1 [--socks-port]=1
    [--server-alive-interval]=1 [--max-retries]=1 [--stable-after]=1
    [--backoff-base]=1 [--backoff-cap]=1
)
DEF_SERVICE_NAME="ssh-monitor"

JUMP=0 JUMP_USER="" SSH_CONFIG="" ONCE=0 DRY_RUN=0
USER_SCOPE=0 SERVICE_NAME=$DEF_SERVICE_NAME
SSH_OPTS=() SSH_CMD=()

log() { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
die() { echo "error: $*" >&2; exit 2; }

# shlex.quote-compatible quoting: tokens made only of safe characters stay
# bare; everything else is single-quoted with embedded quotes escaped.
shquote() {
    if [[ -n $1 && $1 =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
        printf '%s' "$1"
    else
        printf "'%s'" "${1//\'/\'\\\'\'}"
    fi
}
quote_cmd() {
    local out="" t
    for t in "$@"; do out+="$(shquote "$t") "; done
    printf '%s' "${out% }"
}

# ---------------------------------------------------------------------------
# ssh command construction
# ---------------------------------------------------------------------------
CMD=()
build_ssh_command() {
    # A user-provided command is supervised verbatim: no built-in flags are
    # added, so the user keeps full control over what ssh actually does.
    if ((${#SSH_CMD[@]})); then
        CMD=("${SSH_CMD[@]}")
        return
    fi

    CMD=(ssh -N)  # -N: no remote command, tunnel only

    [[ -n ${CFG[--key]} ]] && CMD+=(-i "${CFG[--key]}")

    # Dynamic SOCKS5 forward on the local side.
    CMD+=(-D "${CFG[--socks-port]}")

    # JumpProxy only when -J/--jump is requested. The jump host may use its
    # own login user (--jump-user); it falls back to the target's --user.
    if ((JUMP)); then
        local jump_user=${JUMP_USER:-${CFG[--user]}}
        CMD+=(-J "${jump_user}@${CFG[--jump-host]}:${CFG[--jump-port]}")
    fi

    # Optional ssh config file. Unlike -o options, an -F config DOES propagate
    # to the ProxyJump (-J) inner connection, so it is the way to configure
    # host-key handling / identities for the *jump* host non-interactively.
    [[ -n $SSH_CONFIG ]] && CMD+=(-F "$SSH_CONFIG")

    # Robustness / service-friendly defaults. ssh uses the FIRST value it sees
    # for a given option, so a user --ssh-option can only win if we DROP the
    # built-in default for that key. We therefore emit only the defaults the
    # user did not override, then the user's options.
    local -A user_keys=()
    local o k
    for o in "${SSH_OPTS[@]}"; do
        k=${o%%=*}
        k=${k//[[:space:]]/}
        user_keys[${k,,}]=1
    done
    local kv
    for kv in "ServerAliveInterval=${CFG[--server-alive-interval]}" \
              "ServerAliveCountMax=3" \
              "ExitOnForwardFailure=yes" \
              "StrictHostKeyChecking=accept-new" \
              "BatchMode=yes"; do
        k=${kv%%=*}
        [[ -z ${user_keys[${k,,}]:-} ]] && CMD+=(-o "$kv")
    done
    for o in "${SSH_OPTS[@]}"; do CMD+=(-o "$o"); done

    # Remote SSH port + destination.
    CMD+=(-p "${CFG[--remote-ssh-port]}" "${CFG[--user]}@${CFG[--remote-host]}")
}

# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------
STOP=0 STOP_SIG="" CHILD=""
HAVE_SETSID=0; command -v setsid >/dev/null && HAVE_SETSID=1

on_signal() { STOP=1; STOP_SIG=$1; }

terminate_child() {
    [[ -n $CHILD ]] && kill -0 "$CHILD" 2>/dev/null || return 0
    # Kill the whole process group (child runs via setsid below).
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    local i
    for ((i = 0; i < 100; i++)); do
        kill -0 "$CHILD" 2>/dev/null || return 0
        sleep 0.1
    done
    log "ssh did not exit after SIGTERM; sending SIGKILL"
    kill -KILL -- "-$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
}

port_in_use() {
    # Best-effort (warning only): a listener on the SOCKS port means the bind
    # will fail. Skips silently when `ss` is unavailable.
    command -v ss >/dev/null || return 1
    ss -ltn 2>/dev/null | grep -q "[:.]${CFG[--socks-port]} "
}

# Sleep that wakes up promptly when a stop signal arrives (external `sleep`
# is not interrupted by our traps; a background sleep + `wait` is).
snooze() {
    local end=$((SECONDS + $1)) pid
    while ((!STOP && SECONDS < end)); do
        sleep 0.5 & pid=$!
        wait "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    return 0
}

SESSION_RC=0 SESSION_UPTIME=0
run_ssh_session() {
    # Launch ssh and block until it exits, or until a stop signal arrives —
    # in which case the child (and its process group) is torn down here.
    # Sets SESSION_RC and SESSION_UPTIME.
    build_ssh_command
    if ! command -v "${CMD[0]}" >/dev/null; then
        log "ERROR: \`${CMD[0]}\` not found on PATH"
        return 2
    fi
    log "starting: $(quote_cmd "${CMD[@]}")"
    local start=$SECONDS rc
    if ((HAVE_SETSID)); then
        setsid "${CMD[@]}" & CHILD=$!
    else
        "${CMD[@]}" & CHILD=$!
    fi

    # `wait` returns early (rc > 128) when a trapped signal arrives; loop so
    # spurious wakeups resume waiting and a real stop performs the teardown.
    while :; do
        wait "$CHILD" 2>/dev/null; rc=$?
        if kill -0 "$CHILD" 2>/dev/null; then
            if ((STOP)); then
                log "received ${STOP_SIG}; shutting down ssh"
                terminate_child
                wait "$CHILD" 2>/dev/null; rc=$?
                break
            fi
            continue
        fi
        break
    done
    CHILD=""
    SESSION_RC=$rc
    SESSION_UPTIME=$((SECONDS - start))
    return 0
}

supervise() {
    trap 'on_signal SIGTERM' TERM
    trap 'on_signal SIGINT' INT

    local retries=0 max=${CFG[--max-retries]}
    if ((${#SSH_CMD[@]})); then
        local mode=monitor; ((ONCE)) && mode=once
        log "supervising user-provided command (mode=${mode}, max_retries=${max})"
    else
        local j=off; ((JUMP)) && j=on
        log "SOCKS5 proxy target: 127.0.0.1:${CFG[--socks-port]} (jump=${j}, max_retries=${max})"
    fi

    while ((!STOP)); do
        # The SOCKS port is only known for the built-in tunnel command; a
        # user-provided command may bind anything (or nothing).
        if ((${#SSH_CMD[@]} == 0)) && port_in_use; then
            log "WARNING: local SOCKS port ${CFG[--socks-port]} is not bindable; another process may be using it"
        fi

        run_ssh_session || return $?

        ((STOP)) && break

        if ((ONCE)); then
            log "ssh exited rc=${SESSION_RC} after ${SESSION_UPTIME}s (--once: not restarting)"
            return "$SESSION_RC"
        fi

        # A session that stayed up long enough is considered healthy: reset
        # the retry budget so long-lived tunnels can drop-and-recover
        # indefinitely.
        if ((SESSION_UPTIME >= CFG[--stable-after])); then
            ((retries)) && log "connection was stable for ${SESSION_UPTIME}s; resetting retry counter"
            retries=0
        fi

        ((retries += 1))
        local budget=""
        ((max >= 0)) && budget="/${max}"
        log "ssh exited rc=${SESSION_RC} after ${SESSION_UPTIME}s (failure ${retries}${budget})"

        if ((max >= 0 && retries > max)); then
            log "exhausted ${max} retries; giving up"
            return 3
        fi

        local backoff=${CFG[--backoff-cap]}
        if ((retries - 1 < 30)); then  # avoid 2^n overflow on long outages
            backoff=$((CFG[--backoff-base] * (1 << (retries - 1))))
            ((backoff > CFG[--backoff-cap])) && backoff=${CFG[--backoff-cap]}
        fi
        log "reconnecting in ${backoff}s"
        snooze "$backoff"
    done

    log "stopped cleanly"
    return 0
}

# ---------------------------------------------------------------------------
# systemd integration
# ---------------------------------------------------------------------------
reconstruct_run_args() {
    # Rebuild an explicit `run ...` argv that reproduces this config. Driven
    # by CONN_FLAGS so it can never fall out of sync with the parser — every
    # connection flag is round-tripped with its resolved value, which is what
    # bakes an explicit, self-contained command into the unit.
    RUN_ARGS=(run)
    local flag
    for flag in "${CONN_FLAGS[@]}"; do
        RUN_ARGS+=("$flag" "${CFG[$flag]}")
    done
    ((JUMP)) && RUN_ARGS+=(--jump)
    [[ -n $JUMP_USER ]] && RUN_ARGS+=(--jump-user "$JUMP_USER")
    [[ -n $SSH_CONFIG ]] && RUN_ARGS+=(--ssh-config "$SSH_CONFIG")
    local o
    for o in "${SSH_OPTS[@]}"; do RUN_ARGS+=(--ssh-option "$o"); done
    ((ONCE)) && RUN_ARGS+=(--once)
    ((${#SSH_CMD[@]})) && RUN_ARGS+=(-- "${SSH_CMD[@]}")
}

build_unit() {
    local script exec_start wanted_by desc restart
    script=$(realpath "${BASH_SOURCE[0]}")
    reconstruct_run_args
    exec_start=$(quote_cmd "$script" "${RUN_ARGS[@]}")
    wanted_by=multi-user.target
    (($1)) && wanted_by=default.target
    if ((${#SSH_CMD[@]})); then
        desc="Supervised ssh command (${SSH_CMD[*]})"
    else
        desc="SSH SOCKS5 tunnel (${CFG[--remote-host]} -> 127.0.0.1:${CFG[--socks-port]})"
    fi
    # In --once mode the command must run exactly once: no supervisor restart,
    # and no systemd restart either.
    restart=on-failure
    ((ONCE)) && restart=no

    cat <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target
# StartLimit* live in [Unit]. They cap systemd's own restart storms; the
# in-process --max-retries budget is the primary reconnect policy.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${exec_start}
# The supervisor owns the reconnect policy (--max-retries). systemd Restart is an
# outer safety net for an unexpected supervisor crash ("no" in --once mode).
Restart=${restart}
RestartSec=5
# Clean shutdown: the supervisor traps SIGTERM and tears down ssh; KillMode=mixed
# also reaps the whole cgroup as a backstop so no ssh survives a stop.
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=${wanted_by}
EOF
}

unit_path() {
    if ((USER_SCOPE)); then
        printf '%s' "${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    else
        printf '%s' "/etc/systemd/system/${SERVICE_NAME}.service"
    fi
}

sctl() {
    local cmd=(systemctl)
    ((USER_SCOPE)) && cmd+=(--user)
    cmd+=("$@")
    log "+ $(quote_cmd "${cmd[@]}")"
    "${cmd[@]}"
}

cmd_install() {
    local path
    path=$(unit_path)
    mkdir -p "$(dirname "$path")"
    build_unit "$USER_SCOPE" > "$path"
    log "wrote unit: $path"
    sctl daemon-reload
    sctl enable "$SERVICE_NAME"
    sctl restart "$SERVICE_NAME"
    local rc=$?
    local scope="(system)"
    ((USER_SCOPE)) && scope="--user"
    log "installed. Inspect with: systemctl ${scope} status ${SERVICE_NAME}"
    return $rc
}

cmd_uninstall() {
    sctl stop "$SERVICE_NAME"
    sctl disable "$SERVICE_NAME"
    local path
    path=$(unit_path)
    if [[ -e $path ]]; then
        rm -f "$path"
        log "removed unit: $path"
    fi
    sctl daemon-reload
    return 0
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
    local flag
    cat <<EOF
usage: ssh_monitor.sh [run|install|uninstall|status|print-unit] [options] [-- COMMAND ...]

Supervise an SSH SOCKS5 tunnel (or any ssh command) with auto-reconnect,
and deploy it as a systemd service. See the header of this script for details.

connection options (all subcommands):
EOF
    for flag in "${CONN_FLAGS[@]}"; do
        printf '  %-24s %s (default: %s)\n' "$flag" "${CONN_HELP[$flag]}" "${CFG[$flag]}"
    done
    cat <<EOF
  -J, --jump               use the SSH JumpProxy (-J) setting; omit to connect directly
  --jump-user USER         login user on the jump host (default: same as --user)
  -o, --ssh-option KEY=VALUE
                           extra ssh -o option (repeatable); overrides built-in defaults
  -F, --ssh-config FILE    ssh config file (-F); unlike -o, this also configures the -J jump host
  --once                   run the ssh command exactly once and exit with its status
  [--] COMMAND [ARG ...]   supervise this ssh command verbatim instead of the built-in tunnel

run only:
  --dry-run                print the ssh command and exit

service subcommands only:
  --service-name NAME      systemd service name (default: ${DEF_SERVICE_NAME})
  --user-scope             per-user systemd service (systemctl --user) instead of system-wide
EOF
}

parse_args() {
    local subcmd=$1; shift
    local arg val
    while (($#)); do
        arg=$1
        # --flag=value form
        val=""
        if [[ $arg == --*=* ]]; then
            val=${arg#*=}
            arg=${arg%%=*}
        fi
        if [[ -n ${CFG[$arg]+x} ]]; then
            [[ $arg == "$1" ]] && { val=${2-}; [[ $# -ge 2 ]] || die "argument $arg: expected one value"; shift; }
            if [[ -n ${INT_FLAGS[$arg]:-} && ! $val =~ ^-?[0-9]+$ ]]; then
                die "argument $arg: invalid int value: '$val'"
            fi
            CFG[$arg]=$val
            shift
            continue
        fi
        case $arg in
            -J|--jump) JUMP=1; shift ;;
            --jump-user)
                [[ $arg == "$1" ]] && { val=${2-}; [[ $# -ge 2 ]] || die "argument $arg: expected one value"; shift; }
                JUMP_USER=$val; shift ;;
            -F|--ssh-config)
                if [[ $arg == "$1" ]]; then
                    val=${2-}; [[ $# -ge 2 ]] || die "argument $arg: expected one value"; shift
                fi
                SSH_CONFIG=$val; shift ;;
            -F?*) SSH_CONFIG=${1:2}; shift ;;
            -o|--ssh-option)
                if [[ $arg == "$1" ]]; then
                    val=${2-}; [[ $# -ge 2 ]] || die "argument $arg: expected one value"; shift
                fi
                SSH_OPTS+=("$val"); shift ;;
            -o?*) SSH_OPTS+=("${1:2}"); shift ;;
            --once) ONCE=1; shift ;;
            --dry-run)
                [[ $subcmd == run ]] || die "argument --dry-run: only valid for 'run'"
                DRY_RUN=1; shift ;;
            --service-name)
                [[ $subcmd == run ]] && die "argument --service-name: not valid for 'run'"
                [[ $arg == "$1" ]] && { val=${2-}; [[ $# -ge 2 ]] || die "argument $arg: expected one value"; shift; }
                SERVICE_NAME=$val; shift ;;
            --user-scope)
                [[ $subcmd == run ]] && die "argument --user-scope: not valid for 'run'"
                USER_SCOPE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; SSH_CMD=("$@"); break ;;
            -*) die "unrecognized argument: $arg" ;;
            *) SSH_CMD=("$@"); break ;;  # remainder: supervise verbatim
        esac
    done
}

main() {
    local subcmd
    case ${1-} in
        run|install|uninstall|status|print-unit) subcmd=$1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) subcmd=run ;;  # default to `run` when no subcommand is given
    esac
    parse_args "$subcmd" "$@"

    case $subcmd in
        run)
            if ((DRY_RUN)); then
                build_ssh_command
                quote_cmd "${CMD[@]}"; echo
                return 0
            fi
            supervise ;;
        install)    cmd_install ;;
        uninstall)  cmd_uninstall ;;
        status)     sctl status "$SERVICE_NAME" ;;
        print-unit) build_unit "$USER_SCOPE" ;;
    esac
}

main "$@"
