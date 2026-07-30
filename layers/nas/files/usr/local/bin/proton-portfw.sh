#!/bin/sh
# Renew the Proton NAT-PMP mapping and sync qBittorrent's listen port to it.
# Runs on the host: natpmpc through the qbt namespace, the WebUI over the
# veth. Driven by qbt-portfw.timer every 30 s against a 60 s lease.
set -eu

NETNS=qbt
GATEWAY=10.2.0.1
QBT_API=http://10.200.0.2:8080/api/v2
# Optional WEBUI_USER=/WEBUI_PASS=, on the array beside the WireGuard keys.
# Without them this falls back to unauthenticated calls, which only work with
# the subnet whitelist enabled — and the whitelist authenticates nobody (the
# MASQUERADE collapses every client to one address), so set real credentials.
CREDS=/etc/wireguard/qbt-webui.creds

COOKIES=""
cleanup() { [ -z "$COOKIES" ] || rm -f "$COOKIES"; }
trap cleanup EXIT INT TERM

api() { # api <path> [curl args...]
  path="$1"; shift
  if [ -n "$COOKIES" ]; then
    curl -fsS --max-time 10 -b "$COOKIES" "$QBT_API/$path" "$@"
  else
    curl -fsS --max-time 10 "$QBT_API/$path" "$@"
  fi
}

### ── renew the mapping ────────────────────────────────────────────────────
UDP="$(ip netns exec "$NETNS" natpmpc -a 1 0 udp 60 -g "$GATEWAY")"
TCP="$(ip netns exec "$NETNS" natpmpc -a 1 0 tcp 60 -g "$GATEWAY")"

port_of() { echo "$1" | sed -n 's/.*Mapped public port \([0-9]\{1,5\}\).*/\1/p' | head -1; }
UDP_PORT="$(port_of "$UDP")"
TCP_PORT="$(port_of "$TCP")"
[ -n "$TCP_PORT" ] || { echo "ERROR: could not parse a port from natpmpc:" >&2
                        printf '%s\n' "$TCP" >&2; exit 1; }
[ "$UDP_PORT" = "$TCP_PORT" ] || \
  echo "WARNING: Proton mapped different udp/tcp ports ($UDP_PORT/$TCP_PORT); using $TCP_PORT" >&2
PORT="$TCP_PORT"

### ── authenticate if credentials are configured ───────────────────────────
if [ -r "$CREDS" ]; then
  # shellcheck source=/dev/null
  . "$CREDS"
  # Validate before expanding: under set -u a half-filled creds file would
  # otherwise die with an opaque "parameter not set" on every timer tick.
  [ -n "${WEBUI_USER:-}" ] && [ -n "${WEBUI_PASS:-}" ] || {
    echo "ERROR: $CREDS must set both WEBUI_USER= and WEBUI_PASS=" >&2; exit 1; }
  COOKIES="$(mktemp)"
  curl -fsS --max-time 10 -c "$COOKIES" \
    --data-urlencode "username=${WEBUI_USER}" \
    --data-urlencode "password=${WEBUI_PASS}" \
    "$QBT_API/auth/login" >/dev/null
fi

### ── sync the port ────────────────────────────────────────────────────────
PREFS="$(api app/preferences)"
CURRENT="$(echo "$PREFS" | sed -n 's/.*"listen_port":\([0-9]\{1,5\}\).*/\1/p')"
RANDOM_PORT="$(echo "$PREFS" | sed -n 's/.*"random_port":\(true\|false\).*/\1/p')"
UPNP="$(echo "$PREFS" | sed -n 's/.*"upnp":\(true\|false\).*/\1/p')"

# A forwarded port is pointless if qBittorrent re-randomises it or UPnP moves
# it; pin those off in the same call.
if [ "$CURRENT" = "$PORT" ] && [ "$RANDOM_PORT" = false ] && [ "$UPNP" = false ]; then
  exit 0
fi
api app/setPreferences --data-urlencode \
  "json={\"listen_port\":$PORT,\"random_port\":false,\"upnp\":false}" >/dev/null
echo "qBittorrent listen_port -> $PORT (random_port/upnp pinned off)"
