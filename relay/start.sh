#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$HOME/.config/herdr-remote/config.env"
WS_PORT="${HERDR_RELAY_PORT:-8375}"

RELAY_PID=""
TUNNEL_PID=""
TUNNEL_LOG=""
TUNNEL_URL=""

cleanup() {
    echo ""
    echo "Shutting down..."
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null && wait "$TUNNEL_PID" 2>/dev/null
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null && wait "$RELAY_PID" 2>/dev/null
    [ -n "$TUNNEL_LOG" ] && rm -f "$TUNNEL_LOG"
    echo "Done."
    exit 0
}

trap cleanup INT TERM EXIT

echo "herdr-remote relay"
echo ""

# Load config if available
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Reuse a persistent token across restarts so saved relay URLs keep working.
# If HERDR_RELAY_TOKEN was already set (config.env or env), keep it; otherwise
# generate one and persist it to config.env so the next run is stable.
if [ -z "${HERDR_RELAY_TOKEN:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        HERDR_RELAY_TOKEN="$(openssl rand -hex 16)"
    else
        HERDR_RELAY_TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [ -f "$CONFIG_FILE" ]; then
        # Merge: replace an existing HERDR_RELAY_TOKEN line, keep other settings
        if grep -q '^HERDR_RELAY_TOKEN=' "$CONFIG_FILE"; then
            sed -i '' "s/^HERDR_RELAY_TOKEN=.*/HERDR_RELAY_TOKEN=${HERDR_RELAY_TOKEN}/" "$CONFIG_FILE"
        else
            echo "HERDR_RELAY_TOKEN=${HERDR_RELAY_TOKEN}" >> "$CONFIG_FILE"
        fi
    else
        echo "HERDR_RELAY_TOKEN=${HERDR_RELAY_TOKEN}" > "$CONFIG_FILE"
    fi
fi
export HERDR_RELAY_TOKEN

# 1. Start relay
echo "Starting relay on :$WS_PORT (token auth on)..."
uv run "$SCRIPT_DIR/herdr_relay.py" &
RELAY_PID=$!
sleep 2

if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "Error: Relay failed to start. Check if port $WS_PORT is in use."
    echo "  lsof -iTCP:$WS_PORT"
    RELAY_PID=""
    exit 1
fi
echo "Relay running (pid $RELAY_PID)"

# 2. Start tunnel (if cloudflared available)
if command -v cloudflared >/dev/null 2>&1; then
    TUNNEL_MODE="${HERDR_TUNNEL_MODE:-temp}"

    if [ "$TUNNEL_MODE" = "named" ] && [ -n "$HERDR_TUNNEL_NAME" ]; then
        echo "Starting named tunnel ($HERDR_TUNNEL_NAME)..."
        CF_CONFIG="$HOME/.cloudflared/config-herdr.yml"
        if [ -f "$CF_CONFIG" ]; then
            cloudflared tunnel --config "$CF_CONFIG" run "$HERDR_TUNNEL_NAME" &
            TUNNEL_PID=$!
        else
            echo "Warning: Tunnel config not found at $CF_CONFIG"
            echo "Run install-service.sh to configure the named tunnel."
            echo "Falling back to temp tunnel..."
            TUNNEL_MODE="temp"
        fi
    fi

    if [ "$TUNNEL_MODE" = "temp" ]; then
        echo "Starting temp tunnel..."
        TUNNEL_LOG="$(mktemp "${TMPDIR:-/tmp}/herdr-tunnel.XXXXXX")"
        cloudflared tunnel --url "http://localhost:$WS_PORT" >"$TUNNEL_LOG" 2>&1 &
        TUNNEL_PID=$!
        sleep 4

        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            echo "Warning: Tunnel failed to start. Relay still running locally."
            TUNNEL_PID=""
        else
            # Extract URL from the "Your quick Tunnel has been created" box in the
            # cloudflared log. Poll up to ~30s; never match api.trycloudflare.com
            # (appears in request/error lines, not the assigned hostname).
            for _ in $(seq 1 30); do
                TUNNEL_URL=$(awk '
                    /Visit it at/ {ready=1}
                    ready && match($0, /https:\/\/[A-Za-z0-9-]+\.trycloudflare\.com/) {
                        print substr($0, RSTART, RLENGTH); exit
                    }' "$TUNNEL_LOG")
                if [ -n "$TUNNEL_URL" ]; then break; fi
                sleep 1
            done
            if [ -z "$TUNNEL_URL" ] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
                echo "Warning: Tunnel process died. Last log lines:"
                tail -3 "$TUNNEL_LOG" | sed 's/^/  /'
                TUNNEL_PID=""
            fi
            if [ -z "$TUNNEL_URL" ]; then
                echo "Warning: Could not detect tunnel URL. Check: cat $TUNNEL_LOG"
            fi
        fi
    fi

    if [ "$TUNNEL_MODE" = "none" ]; then
        echo "Tunnel disabled (config: HERDR_TUNNEL_MODE=none)"
    fi
else
    echo "cloudflared not found — running local only."
    echo "Install: brew install cloudflared"
fi

echo ""
echo "============================================================"
echo "  herdr-remote ready — press Ctrl+C to stop"
echo ""
if [ -n "$TUNNEL_URL" ]; then
    echo "  Open on your phone (web app):"
    echo "    ${TUNNEL_URL}?token=${HERDR_RELAY_TOKEN}"
    echo ""
    echo "  WebSocket for TUI / Telegram bot (HERDR_RELAY):"
    echo "    wss://${TUNNEL_URL#https://}?token=${HERDR_RELAY_TOKEN}"
elif [ "${TUNNEL_MODE:-}" = "named" ] && [ -n "${HERDR_TUNNEL_NAME:-}" ]; then
    echo "  Named tunnel: $HERDR_TUNNEL_NAME"
    echo "  Append ?token=$HERDR_RELAY_TOKEN to your tunnel hostname."
else
    echo "  Open in browser (local only):"
    echo "    http://127.0.0.1:$WS_PORT?token=$HERDR_RELAY_TOKEN"
    echo ""
    echo "  WebSocket for TUI / Telegram bot (HERDR_RELAY):"
    echo "    ws://127.0.0.1:$WS_PORT?token=$HERDR_RELAY_TOKEN"
fi
echo ""
echo "  Token: $HERDR_RELAY_TOKEN"
echo "============================================================"
echo ""

# Wait for relay (primary process)
wait "$RELAY_PID"
