#!/bin/sh
# kryaken.omarchy.vless backend: manage an Xray VLESS tunnel as a systemd unit.
#
# Profiles: every profile is a complete xray client config stored under
# /etc/xray-vpn/profiles/<name>.json. The active one is mirrored to
# /etc/xray-vpn/config.json for the systemd service. On first install the
# previous config (or a built-in seed) becomes the "default" profile.
# Profiles are added from vless:// links or imported from xray/v2rayN JSON.
#
# Modes:
#   proxy  (default) - local SOCKS 127.0.0.1:1080 and HTTP 127.0.0.1:1081.
#   system           - transparent: iptables REDIRECT of OUTBOUND TCP 80/443
#                      into xray :1082. UDP/QUIC is left direct (the tunnel
#                      is gRPC/TCP, it cannot carry UDP).
#
# Privileges: writing /etc/xray-vpn, the unit and iptables require root.
# Uses sudo from a TTY, pkexec from the shell panel (like kryaken.omarchy.zapret).
set -u

SERVICE="xray-vpn"
CONFDIR="/etc/xray-vpn"
CONFIG="$CONFDIR/config.json"
MODE_FILE="$CONFDIR/mode"
PROFILES_DIR="$CONFDIR/profiles"
ACTIVE_FILE="$CONFDIR/active"
UNIT="/etc/systemd/system/xray-vpn.service"
INSTALLED_BACKEND="$CONFDIR/backend.sh"

# No built-in server seed: profiles are purely user-supplied (added from
# vless:// links or imported JSON configs). A pre-existing config from an
# older install is migrated into the "default" profile on first run.
SOCKS_PORT=1080
HTTP_PORT=1081
TPROXY_PORT=1082
PROBE_SOCKS=1083
PROBE_HTTP=1084
REDIRECT_PORTS="80,443"

PY=""
command -v python3 >/dev/null 2>&1 && PY=$(command -v python3)

# Locate factory.py next to this script (works through sudo/pkexec re-exec).
SELF=""
case "${BASH_SOURCE:-}" in
  "") ;;
  *) SELF=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) ;;
esac
[ -n "$SELF" ] || SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd 2>/dev/null)
FACTORY=""
[ -n "$SELF" ] && [ -f "$SELF/factory.py" ] && FACTORY="$SELF/factory.py"

if [ "$(id -u)" = 0 ]; then
  run() { "$@"; }
elif [ -t 0 ]; then
  run() { "${KDK_VPN_PRIV:-sudo}" "$@"; }
else
  run() { "${KDK_VPN_PRIV:-pkexec}" "$@"; }
fi

sys() { command -v systemctl >/dev/null 2>&1 && systemctl "$@" 2>/dev/null; }

os_is() {
  sed -n 's/^\(ID\|ID_LIKE\)=//p' /etc/os-release 2>/dev/null | tr -d '"' | tr ' ' '\n' | grep -qi "^$1$"
}

# Copy-pasteable install hint for a missing dependency.
install_hint() {
  case "${1:-}" in
    xray)
      if command -v paru >/dev/null 2>&1; then printf '%s\n' "paru -S xray-bin"; return 0; fi
      if command -v yay >/dev/null 2>&1; then printf '%s\n' "yay -S xray-bin"; return 0; fi
      if os_is debian || os_is ubuntu; then printf '%s\n' "sudo apt install xray"; return 0; fi
      printf '%s\n' "install xray (https://xtls.github.io/en/install.html)"
      ;;
    python)
      if os_is arch; then printf '%s\n' "sudo pacman -S python"; else printf '%s\n' "install python3 (https://www.python.org)"; fi
      ;;
    curl)
      if os_is arch; then printf '%s\n' "sudo pacman -S curl"; else printf '%s\n' "install curl (https://curl.se)"; fi
      ;;
    *) printf '%s\n' "" ;;
  esac
}

# Read-only dependency report (included in `status` so the panel can offer
# one-click setup against missing packages; no privilege needed).
deps_json() {
  x_ok=false; x_h=""
  py_ok=false; py_h=""
  cur_ok=false; cur_h=""
  sys_ok=false
  if command -v xray >/dev/null 2>&1 || [ -x /usr/bin/xray ]; then x_ok=true; else x_h=$(install_hint xray); fi
  command -v systemctl >/dev/null 2>&1 && sys_ok=true
  if command -v python3 >/dev/null 2>&1; then py_ok=true; else py_h=$(install_hint python); fi
  if command -v curl >/dev/null 2>&1; then cur_ok=true; else cur_h=$(install_hint curl); fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$x_ok" "$x_h" "$sys_ok" "$py_ok" "$py_h" "$cur_ok" "$cur_h" <<'PYEOF'
import json, sys
def b(s): return s == "true"
x_ok, x_h, sys_ok, py_ok, py_h, cur_ok, cur_h = sys.argv[1:]
deps = []
for n, ok, h in (("xray binary", x_ok, x_h), ("systemd", sys_ok, ""),
                 ("python3", py_ok, py_h), ("curl", cur_ok, cur_h)):
    deps.append({"n": n, "ok": b(ok), "h": h if not b(ok) else ""})
print(json.dumps(deps))
PYEOF
  else
    printf '[{"n":"xray binary","ok":%s,"h":"%s"},{"n":"systemd","ok":%s,"h":""},{"n":"python3","ok":false,"h":"install python3"},{"n":"curl","ok":%s,"h":"%s"}]\n' \
      "$x_ok" "$(printf '%s' "$x_h" | tr -d '"')" "$sys_ok" "$cur_ok" "$(printf '%s' "$cur_h" | tr -d '"')"
  fi
}

# Terminal-friendly setup validation (exit 0 when everything is in place).
doctor() {
  rc=0
  if command -v xray >/dev/null 2>&1 || [ -x /usr/bin/xray ]; then
    printf '%s\n' "ok     xray binary"
  else
    printf '%s\n' "missing xray binary — $(install_hint xray)"
    rc=1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf '%s\n' "ok     systemd"
  else
    printf '%s\n' "missing systemd"
    rc=1
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "ok     python3"
  else
    printf '%s\n' "missing python3 — $(install_hint python)"
    rc=1
  fi
  if command -v curl >/dev/null 2>&1; then
    printf '%s\n' "ok     curl"
  else
    printf '%s\n' "missing curl — $(install_hint curl)"
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then printf '%s\n' "ok     all dependencies present"; fi
  return "$rc"
}

unit_known() {
  sys list-unit-files --no-legend "$SERVICE.service" 2>/dev/null | grep -q . || {
    sleep 1
    sys list-unit-files --no-legend "$SERVICE.service" 2>/dev/null | grep -q .
  }
}

unit_active() { [ "$(sys is-active "$SERVICE")" = "active" ]; }
unit_enabled() { [ "$(sys is-enabled "$SERVICE")" = "enabled" ]; }

is_installed() {
  command -v xray >/dev/null 2>&1 && [ -r "$CONFIG" ] && unit_known
}

get_mode() {
  if [ -r "$MODE_FILE" ] && m=$(cat "$MODE_FILE") && [ -n "$m" ]; then
    printf '%s\n' "$m"
  else
    printf '%s\n' "proxy"
  fi
}

if [ -x /usr/bin/xray ]; then
  XRAY=/usr/bin/xray
else
  XRAY=$(command -v xray 2>/dev/null || echo "/usr/bin/xray")
fi

factory() {
  [ -n "$PY" ] && [ -n "$FACTORY" ] || { echo "python3/factory.py required" >&2; return 1; }
  "$PY" "$FACTORY" "$@"
}

profile_names() {
  [ -d "$PROFILES_DIR" ] || return 0
  for f in "$PROFILES_DIR"/*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json
  done
}

active_profile() {
  [ -r "$ACTIVE_FILE" ] || return 1
  a=$(cat "$ACTIVE_FILE" 2>/dev/null)
  [ -n "$a" ] && [ -f "$PROFILES_DIR/$a.json" ] || return 1
  printf '%s\n' "$a"
}

set_active() {
  printf '%s\n' "$1" > "$ACTIVE_FILE" 2>/dev/null || return 1
  chmod 644 "$ACTIVE_FILE" 2>/dev/null
  return 0
}

# Root: make the profile store exist, migrating a pre-existing config into the
# "default" profile on first run (a fresh install starts with no profiles),
# then mirror the active profile into the live config.
ensure_profiles_ready() {
  mkdir -p "$PROFILES_DIR" 2>/dev/null || return 1
  chmod 755 "$PROFILES_DIR" 2>/dev/null
  if ! ls "$PROFILES_DIR"/*.json >/dev/null 2>&1; then
    if [ -r "$CONFIG" ]; then
      cp "$CONFIG" "$PROFILES_DIR/default.json" 2>/dev/null || return 1
      chmod 600 "$PROFILES_DIR/default.json" 2>/dev/null
    fi
  fi
  if ! ls "$PROFILES_DIR"/*.json >/dev/null 2>&1; then
    return 0
  fi
  if ! active_profile >/dev/null 2>&1; then
    first=""
    for f in "$PROFILES_DIR"/*.json; do
      [ -e "$f" ] || continue
      first=$(basename "$f" .json)
      break
    done
    [ -n "$first" ] || return 1
    set_active "$first" || return 1
  fi
  ensure_active_config || return 1
}

# Root: mirror the active profile into the live config.json. No-op when no
# profile is active.
ensure_active_config() {
  active_profile >/dev/null 2>&1 || return 0
  a=$(active_profile)
  p="$PROFILES_DIR/$a.json"
  [ -r "$p" ] || return 1
  cp "$p" "$CONFIG" && chmod 644 "$CONFIG"
}

unit_text() {
  cat <<EOF
[Unit]
Description=Xray VLESS VPN tunnel (kryaken.omarchy.vless)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY run -c $CONFIG
ExecStartPost=/bin/sleep 0.1
ExecStartPost=$INSTALLED_BACKEND rules-on
ExecStopPost=$INSTALLED_BACKEND rules-off
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

ensure_install() {
  mkdir -p "$CONFDIR" || return 1
  # Copy backend.sh into the privileged directory so the systemd unit and
  # the pkexec serve helper never re-execute a user-writable file as root.
  local src
  src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
  if [ "$src" != "$INSTALLED_BACKEND" ] && [ -r "$src" ]; then
    cp -- "$src" "$INSTALLED_BACKEND" 2>/dev/null || return 1
    chmod 755 "$INSTALLED_BACKEND" 2>/dev/null
  fi
  ensure_profiles_ready || return 1
  [ -r "$UNIT" ] || unit_text > "$UNIT" 2>/dev/null || return 1
  [ -r "$MODE_FILE" ] || printf '%s\n' "proxy" > "$MODE_FILE" 2>/dev/null
  sys daemon-reload
}

server_ips() {
  a=$(active_profile) || return 0
  server_of "$PROFILES_DIR/$a.json" | cut -d: -f1 | while read -r h; do
    [ -n "$h" ] || continue
    getent ahosts "$h" 2>/dev/null | awk '{print $1}' | sort -u
  done
}

server_of() {
  file="${1:-}"
  if [ -z "$file" ]; then
    a=$(active_profile) || { printf '%s\n' ""; return 0; }
    file="$PROFILES_DIR/$a.json"
  fi
  if [ -n "$PY" ] && [ -r "$file" ]; then
    s=$("$PY" - "$file" <<'EOF'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    for ob in c.get("outbounds", []):
        for v in ob.get("settings", {}).get("vnext", []):
            if v.get("address"):
                print("%s:%s" % (v["address"], v.get("port", 443)))
                sys.exit(0)
except Exception:
    pass
EOF
)
    [ -n "$s" ] && { printf '%s\n' "$s"; return 0; }
  fi
  printf '%s\n' ""
}

apply_system_rules() {
  command -v iptables >/dev/null 2>&1 || { echo "iptables not available" >&2; return 1; }
  iptables -t nat -N XRAYVPN 2>/dev/null || {
    iptables -t nat -D OUTPUT -j XRAYVPN 2>/dev/null
    iptables -t nat -F XRAYVPN 2>/dev/null
  }
  iptables -t nat -F XRAYVPN 2>/dev/null
  # Roll back the partially-built chain on any failure so we never leave
  # a broken XRAYVPN dangling in the nat table.
  trap 'remove_system_rules 2>/dev/null' ERR
  iptables -t nat -A XRAYVPN -d 127.0.0.0/8 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -d 10.0.0.0/8 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -d 172.16.0.0/12 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -d 192.168.0.0/16 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -d 169.254.0.0/16 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -d 224.0.0.0/4 -j RETURN 2>/dev/null
  iptables -t nat -A XRAYVPN -p udp --dport 53 -j RETURN 2>/dev/null
  for ip in $(server_ips); do
    iptables -t nat -A XRAYVPN -d "$ip" -j RETURN 2>/dev/null
  done
  iptables -t nat -A XRAYVPN -p tcp -m multiport --dports "$REDIRECT_PORTS" -j REDIRECT --to-ports "$TPROXY_PORT" 2>/dev/null
  iptables -t nat -A OUTPUT -j XRAYVPN 2>/dev/null
  trap - ERR
  return 0
}

remove_system_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t nat -D OUTPUT -j XRAYVPN 2>/dev/null
  iptables -t nat -F XRAYVPN 2>/dev/null
  iptables -t nat -X XRAYVPN 2>/dev/null
  return 0
}

# Rule state must reflect the current mode whenever the unit is running.
refresh_rules() {
  if unit_active; then
    if [ "$(get_mode)" = "system" ]; then apply_system_rules; else remove_system_rules; fi
  fi
}

status_json() {
  deps_s=$(deps_json)
  command -v systemctl >/dev/null 2>&1 || {
    printf '{"installed":false,"active":false,"enabled":false,"mode":"proxy","config":null,"configFile":null,"profiles":[],"activeProfile":"","server":"","error":"systemctl not available","deps":%s}\n' \
      "$deps_s"
    return 0
  }
  inst=false
  act=false
  ena=false
  if is_installed; then
    inst=true
    unit_active && act=true
    unit_enabled && ena=true
  fi
  cfg_line="null"
  [ -r "$CONFIG" ] && cfg_line="\"$CONFIG\""
  cf_line="null"
  srv=$(server_of)
  plist="[]"
  aq=""
  if [ -n "$PY" ]; then
    names=$(profile_names)
    if [ -n "$names" ]; then
      plist=$(printf '%s\n' "$names" | "$PY" -c 'import json,sys;print(json.dumps(sys.stdin.read().split()))')
    fi
    if active_profile >/dev/null 2>&1; then
      aq=$(active_profile)
      [ -f "$PROFILES_DIR/$aq.json" ] && cf_line="\"$PROFILES_DIR/$aq.json\""
    fi
    srv=$("$PY" -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$srv")
    aq=$("$PY" -c 'import json,sys;print(json.dumps(sys.argv[1] if len(sys.argv)>1 else ""))' "$aq")
  else
    serversafe=$(printf '%s' "$srv" | tr -cd 'A-Za-z0-9.:_/-')
    srv="\"$serversafe\""
    aq="\"\""
  fi
  printf '{"installed":%s,"active":%s,"enabled":%s,"mode":"%s","config":%s,"configFile":%s,"profiles":%s,"activeProfile":%s,"server":%s,"error":"","deps":%s}\n' \
    "$inst" "$act" "$ena" "$(get_mode)" "$cfg_line" "$cf_line" "$plist" "$aq" "$srv" "$deps_s"
}

test_json() {
  if ! unit_active; then
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"tunnel not running"}'
    return 0
  fi
  command -v curl >/dev/null 2>&1 || {
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"curl not available"}'
    return 0
  }
  start_s=$(date +%s)
  start_ns=$(date +%s%N)
  ip=$(curl -sS -m 8 -x socks5h://127.0.0.1:$SOCKS_PORT https://api.ipify.org 2>/dev/null)
  rc=$?
  if [ $rc -eq 0 ] && [ -n "$ip" ]; then
    lat=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
    printf '{"ok":true,"exitIp":"%s","latencyMs":%s,"error":""}\n' "$ip" "$lat"
  else
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"proxy test failed"}'
  fi
}

probe_profile() {
  name="${2:-}"
  [ -r "$PROFILES_DIR/$name.json" ] || {
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"no such profile"}'
    return 1
  }
  [ -n "$PY" ] && [ -n "$FACTORY" ] || {
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"python3/factory.py required"}'
    return 1
  }
  command -v curl >/dev/null 2>&1 || {
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"curl not available"}'
    return 1
  }
  tmp=$(mktemp /tmp/kryaken-vpn-probe-XXXXXX.json) || return 1
  out=$(factory import "$PROFILES_DIR/$name.json" --probe 2>/dev/null) || {
    rm -f "$tmp"
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"profile build failed"}'
    return 1
  }
  printf '%s\n' "$out" | sed '1d' > "$tmp"
  "$XRAY" run -c "$tmp" >/dev/null 2>&1 &
  pid=$!
  sleep 1.5
  start_ns=$(date +%s%N)
  ip=$(curl -sS -m 8 -x socks5h://127.0.0.1:$PROBE_SOCKS https://api.ipify.org 2>/dev/null)
  rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$tmp"
  if [ $rc -eq 0 ] && [ -n "$ip" ]; then
    lat=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
    printf '{"ok":true,"exitIp":"%s","latencyMs":%s,"error":""}\n' "$ip" "$lat"
  else
    printf '%s\n' '{"ok":false,"exitIp":null,"error":"probe failed - server unreachable"}'
  fi
  return 0
}

add_profile() {
  name="${3:-}"
  input="${4:-}"
  [ -n "$input" ] || {
    echo "usage: $0 profiles add [name] <vless://link | path-to-json>" >&2
    return 2
  }
  case "$name" in
    "") ;;
    *[!A-Za-z0-9._-]*) echo "invalid profile name: $name" >&2; return 1 ;;
  esac
  [ -d "$PROFILES_DIR" ] || mkdir -p "$CONFDIR" "$PROFILES_DIR" 2>/dev/null || { echo "cannot create $PROFILES_DIR" >&2; return 1; }
  chmod 755 "$PROFILES_DIR" 2>/dev/null
  case "$input" in
    vless://*|VLESS://*)
      out=$(factory vless "$input" 2>/dev/null) || { echo "cannot parse vless:// link" >&2; return 1; }
      ;;
    *)
      [ -f "$input" ] || { echo "no such file: $input" >&2; return 1; }
      out=$(factory import "$input" 2>/dev/null) || { echo "cannot import JSON config" >&2; return 1; }
      ;;
  esac
  dname=$(printf '%s\n' "$out" | sed -n '1s/^NAME:\(.*\)$/\1/p')
  json=$(printf '%s\n' "$out" | sed '1d')
  [ -n "$name" ] || name=$(printf '%s' "$dname" | tr -cs 'A-Za-z0-9._-' '_')
  [ -n "$name" ] || name="imported"
  [ -e "$PROFILES_DIR/$name.json" ] && { echo "profile $name already exists" >&2; return 1; }
  printf '%s\n' "$json" > "$PROFILES_DIR/$name.json" || { echo "write failed" >&2; return 1; }
  chmod 600 "$PROFILES_DIR/$name.json" 2>/dev/null
  # First profile ever: activate it straight away so the tunnel is usable.
  if ! active_profile >/dev/null 2>&1; then
    set_active "$name" || return 1
    ensure_active_config >/dev/null 2>&1
    if unit_active; then sys restart "$SERVICE" 2>/dev/null; refresh_rules; fi
  fi
  echo "$name"
}

select_profile() {
  name="${3:-}"
  [ -f "$PROFILES_DIR/$name.json" ] || { echo "no such profile: $name" >&2; return 1; }
  set_active "$name" || return 1
  ensure_active_config || { echo "cannot deploy config" >&2; return 1; }
  if unit_active; then sys restart "$SERVICE" 2>/dev/null; refresh_rules; fi
  echo ok
}

remove_profile() {
  name="${3:-}"
  [ -f "$PROFILES_DIR/$name.json" ] || { echo "no such profile: $name" >&2; return 1; }
  a=""
  active_profile >/dev/null 2>&1 && a=$(active_profile)
  rm -f "$PROFILES_DIR/$name.json"
  if [ "$a" = "$name" ]; then
    rest=""
    for f in "$PROFILES_DIR"/*.json; do
      [ -e "$f" ] || continue
      rest=$(basename "$f" .json)
      break
    done
    if [ -n "$rest" ]; then
      set_active "$rest" || return 1
      ensure_active_config || return 1
      if unit_active; then sys restart "$SERVICE" 2>/dev/null; refresh_rules; fi
    else
      rm -f "$ACTIVE_FILE"
      remove_system_rules
      sys stop "$SERVICE" 2>/dev/null
    fi
  fi
  echo ok
}

rename_profile() {
  old="${3:-}"
  new="${4:-}"
  [ -f "$PROFILES_DIR/$old.json" ] || { echo "no such profile: $old" >&2; return 1; }
  case "$new" in *[!A-Za-z0-9._-]*|"") echo "invalid profile name: $new" >&2; return 1 ;; esac
  [ -e "$PROFILES_DIR/$new.json" ] && { echo "profile $new already exists" >&2; return 1; }
  mv "$PROFILES_DIR/$old.json" "$PROFILES_DIR/$new.json" || return 1
  a=""
  active_profile >/dev/null 2>&1 && a=$(active_profile)
  if [ "$a" = "$old" ]; then
    set_active "$new" || return 1
    ensure_active_config || return 1
    if unit_active; then sys restart "$SERVICE" 2>/dev/null; refresh_rules; fi
  fi
  echo ok
}

run_root() { exec "${KDK_VPN_PRIV:-pkexec}" "$0" "$@"; }
run_sudo() { exec "${KDK_VPN_PRIV:-sudo}" "$0" "$@"; }

cmd="${1:-status}"

needs_root() {
  case "$cmd" in
    start|stop|restart|toggle|enable|disable|mode|install|rules-on|rules-off)
      if [ "$(id -u)" != 0 ]; then
        if [ -t 0 ]; then run_sudo "$@"; else run_root "$@"; fi
      fi
      ;;
    profiles)
      case "${2:-list}" in
        add|remove|select|rename)
          if [ "$(id -u)" != 0 ]; then
            if [ -t 0 ]; then run_sudo "$@"; else run_root "$@"; fi
          fi
          ;;
      esac
      ;;
  esac
}

usage() {
  cat <<EOF
usage: $0 {status|installed|start|stop|restart|toggle|enable|disable|mode|test|logs [n]|probe <name>|doctor|serve}
       $0 profiles {list|add [<name>] <vless://link|path-to-json>|remove <name>|select <name>|rename <old> <new>}
EOF
}

# Elevated, long-lived driver used by the shell panel: reads one JSON request
# per line on stdin, runs the backend CLI with the request's argv (as root,
# since pkexec launched us) and replies with one JSON line per request. Keeps
# running until stdin closes, so pkexec is only ever invoked once per session.
serve() {
  command -v python3 >/dev/null 2>&1 || {
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' '{"code":1,"out":"","err":"serve requires python3"}'
    done
    return 0
  }
  exec python3 -c '
import json, os, subprocess, sys
script = sys.argv[1]
def respond(rid, code, out, err):
    sys.stdout.write(json.dumps({"id": rid, "code": code, "out": out, "err": err}, ensure_ascii=True) + "\n")
    sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    rid = None
    try:
        req = json.loads(line)
        rid = req.get("id")
        args = req.get("args")
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ValueError("args must be a list of strings")
        if args and args[0] == "serve":
            raise ValueError("serve cannot nest")
        p = subprocess.run([script] + args, capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL)
        respond(rid, p.returncode, p.stdout, p.stderr)
    except Exception as e:
        respond(rid, 1, "", "serve error: %s" % e)
' "$INSTALLED_BACKEND"
}

needs_root "$@"

case "$cmd" in
  status) status_json ;;
  serve) serve ;;
  installed) is_installed && echo yes || echo no ;;
  install)
    ensure_install || { echo "install failed" >&2; exit 1; }
    echo ok
    ;;
  start)
    ensure_install || { echo "failed to install config/unit" >&2; exit 1; }
    active_profile >/dev/null 2>&1 || { echo "error: no profiles — add one first ($0 profiles add <name> <vless://link|path-to-json>)" >&2; exit 1; }
    sys start "$SERVICE" || { echo "start failed" >&2; exit 1; }
    refresh_rules
    ;;
  stop)
    remove_system_rules
    sys stop "$SERVICE"
    ;;
  restart)
    sys stop "$SERVICE" 2>/dev/null
    ensure_install || { echo "failed to install config/unit" >&2; exit 1; }
    active_profile >/dev/null 2>&1 || { echo "error: no profiles — add one first ($0 profiles add <name> <vless://link|path-to-json>)" >&2; exit 1; }
    sys start "$SERVICE" || { echo "start failed" >&2; exit 1; }
    refresh_rules
    ;;
  toggle)
    if unit_active; then
      remove_system_rules
      sys stop "$SERVICE"
    else
      ensure_install || { echo "failed to install config/unit" >&2; exit 1; }
      active_profile >/dev/null 2>&1 || { echo "error: no profiles — add one first ($0 profiles add <name> <vless://link|path-to-json>)" >&2; exit 1; }
      sys start "$SERVICE" || { echo "start failed" >&2; exit 1; }
      refresh_rules
    fi
    ;;
  enable) sys enable "$SERVICE" ;;
  disable) sys disable "$SERVICE" ;;
  mode)
    m="${2:-}"
    case "$m" in
      proxy|system) ;;
      *) echo "usage: $0 mode {proxy|system}" >&2; exit 2 ;;
    esac
    ensure_install || { echo "failed to install config/unit" >&2; exit 1; }
    printf '%s\n' "$m" > "$MODE_FILE"
    refresh_rules
    echo ok
    ;;
  rules-on) refresh_rules ;;
  rules-off) remove_system_rules ;;
  test) test_json ;;
  probe) probe_profile "$@" ;;
  doctor) doctor ;;
  profiles)
    sub="${2:-list}"
    case "$sub" in
      list) profile_names ;;
      add) add_profile "$@" ;;
      remove) remove_profile "$@" ;;
      select) select_profile "$@" ;;
      rename) rename_profile "$@" ;;
      *) echo "usage: $0 profiles {list|add|remove|select|rename}" >&2; exit 2 ;;
    esac
    ;;
  logs)
    n="${2:-40}"
    journalctl -u "$SERVICE" -n "$n" --no-pager 2>/dev/null | tail -n "$n" || true
    ;;
  *)
    usage
    exit 2
    ;;
esac