#!/bin/bash
# Raketa root session helper (v0.15.0).
#
# Started ONCE per app session by RKRoot through a single administrator-privileges prompt, then
# serves a fixed set of verbs over two FIFOs until the app quits or dies. It is the reason the
# password is asked once per session instead of once per switch.
#
# Args: UID APPPID DIR SUPPORT RESOURCES
#   DIR        root-owned session dir holding the FIFOs `cmd` (app -> helper) and `ack` (helper -> app);
#              both are created, chowned to the person and chmod 600 by the launcher script.
#   SUPPORT    ~/Library/Application Support/Raketa  (config, log, updated cores live here)
#   RESOURCES  <app>.app/Contents/Resources           (the bundled sing-box)
#
# Protocol: one request per line, fields separated by TAB; one reply line per request:
#   OK<TAB><value>   |   ERR<TAB><reason>
# Verbs (nothing else is accepted - there is deliberately no "run this command"):
#   core-start  IFACE MPORT SPORT BIN CFG LOG   kill sing-box, system proxy -> 127.0.0.1, start sing-box; OK <pid>
#   core-stop   IFACE                           kill sing-box, system proxy off
#   proxy-off   IFACE                           system proxy off
#   search-start BIN CFG LOG                    sing-box for the DPI search, no killall, self-destruct in 10 min; OK <pid>
#   search-stop PID                             kill that pid if it is a sing-box
#   quit                                        leave
#
# No polling: the loop blocks in `read -t 120` on a FIFO opened O_RDWR (so it never sees EOF); the
# 120 s wake-ups are bash builtins only (no fork) and exist to notice that the app died.
# Written for bash 3.2 (macOS 10.13 /bin/bash). Debug: RK_HELPER_STUB=1 skips the real tools' paths.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
UIDN="${1:-}"; APPPID="${2:-}"; D="${3:-}"; SUP="${4:-}"; RES="${5:-}"
[ -n "$UIDN" ] && [ -n "$APPPID" ] && [ -p "$D/cmd" ] && [ -p "$D/ack" ] || exit 2
exec 3<>"$D/cmd" 4<>"$D/ack"

ok()  { printf 'OK\t%s\n' "${1:-}" >&4; }
err() { printf 'ERR\t%s\n' "${1:-}" >&4; }

# Free text must not carry shell metacharacters: every value below ends up quoted inside a command.
clean() { case "$1" in ''|*[\'\"\\\`\$\;\&\|\<\>\*\?\!\{\}]*) return 1;; esac; return 0; }
num()   { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
iface_ok() { clean "$1" && [ "${#1}" -le 64 ]; }
phys()  { ( cd "$1" 2>/dev/null && pwd -P ); }

# A path is acceptable when its physical directory is inside the allowed root, it is not itself a
# symlink, and it has no "..". (Physical = symlinks in the parents are resolved first.)
inside() { # $1 file, $2 root
  local f="$1" root pd
  clean "$f" || return 1
  case "$f" in /*) ;; *) return 1;; esac
  case "$f" in *..*) return 1;; esac
  [ -L "$f" ] && return 1
  root="$(phys "$2")" || return 1; [ -n "$root" ] || return 1
  pd="$(phys "$(dirname "$f")")" || return 1
  case "$pd" in "$root"|"$root"/*) return 0;; esac
  return 1
}
bin_ok() { # sing-box must be a regular executable named sing-box inside the app or the support dir
  [ "$(basename "$1")" = "sing-box" ] && [ -f "$1" ] && [ -x "$1" ] && { inside "$1" "$RES" || inside "$1" "$SUP"; }
}
sup_ok() { inside "$1" "$SUP"; }

proxy_set() { # iface mport sport
  networksetup -setwebproxy "$1" 127.0.0.1 "$2"
  networksetup -setsecurewebproxy "$1" 127.0.0.1 "$2"
  networksetup -setsocksfirewallproxy "$1" 127.0.0.1 "$3"
}
proxy_off() {
  networksetup -setwebproxystate "$1" off
  networksetup -setsecurewebproxystate "$1" off
  networksetup -setsocksfirewallproxystate "$1" off
}
# Fresh, symlink-free log file owned by the person (noclobber = O_EXCL: never follows a link).
fresh_log() {
  rm -f "$1"
  ( set -C; : > "$1" ) 2>/dev/null || return 1
  chown "$UIDN" "$1" 2>/dev/null || true
}

do_verb() {
  local verb="$1"; shift
  case "$verb" in
  core-start)
    [ $# -eq 6 ] || { err args; return; }
    iface_ok "$1" && num "$2" && num "$3" || { err args; return; }
    bin_ok "$4" && sup_ok "$5" && sup_ok "$6" || { err path; return; }
    killall -9 sing-box 2>/dev/null
    sleep 0.3
    proxy_set "$1" "$2" "$3"
    fresh_log "$6" || { err log; return; }
    "$4" run -c "$5" >> "$6" 2>&1 < /dev/null &
    ok "$!";;
  core-stop)
    [ $# -eq 1 ] && iface_ok "$1" || { err args; return; }
    killall -9 sing-box 2>/dev/null
    proxy_off "$1"
    ok "";;
  proxy-off)
    [ $# -eq 1 ] && iface_ok "$1" || { err args; return; }
    proxy_off "$1"
    ok "";;
  search-start)
    [ $# -eq 3 ] || { err args; return; }
    bin_ok "$1" && sup_ok "$2" && sup_ok "$3" || { err path; return; }
    fresh_log "$3" || { err log; return; }
    "$1" run -c "$2" >> "$3" 2>&1 < /dev/null &
    local p=$!
    # Self-destruct: an app that dies mid-search must not leave a root SOCKS listener behind.
    ( sleep 600; case "$(ps -p "$p" -o comm= 2>/dev/null)" in *sing-box) kill "$p";; esac ) >/dev/null 2>&1 < /dev/null &
    ok "$p";;
  search-stop)
    [ $# -eq 1 ] && case "$1" in ''|*[!0-9]*) false;; *) [ "$1" -gt 1 ];; esac || { err args; return; }
    case "$(ps -p "$1" -o comm= 2>/dev/null)" in *sing-box) kill "$1" 2>/dev/null;; esac
    ok "";;
  *) err verb;;
  esac
}

while :; do
  line=""
  if IFS= read -r -t 120 line <&3; then
    [ "$line" = "quit" ] && { ok ""; break; }
    OLDIFS="$IFS"; IFS=$'\t'; set -f
    # shellcheck disable=SC2086
    set -- $line
    IFS="$OLDIFS"; set +f
    [ $# -ge 1 ] || { err empty; continue; }
    do_verb "$@"
  else
    # timeout (status > 128): is the app still there?
    kill -0 "$APPPID" 2>/dev/null || break
  fi
done
rm -rf "$D" 2>/dev/null
exit 0
