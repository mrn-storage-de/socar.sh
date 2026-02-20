#!/bin/bash
# version: 1.0
# 
# >> publishers note:
# This was generated with claude.ai (free). I claim no originality.
#
# socar.sh - Unix socket <-> TCP/UDP bridge using socat
#
# Usage: socar.sh name:port|port:name|port:port[/tcp|/udp] [...]
#
# Each argument specifies a pair to bridge:
#   name:port   (yank) listen on a Unix socket, forward to a TCP/UDP port
#   port:name   (yeet) listen on a TCP/UDP port, forward to a Unix socket
#   port:port   (bridge) both of the above, socket named after the target port
#
# The direction is inferred from which side is numeric:
#   http:80  ->  yank: /tmp/http.sock -> localhost:80
#   80:http  ->  yeet: localhost:80   -> /tmp/http.sock
#   80:81    ->  bridge: both of the above, socket named 81.sock
#
# Protocol defaults to TCP, override with /udp suffix:
#   http:80/udp
#
# Environment variables:
#   SOCK_DIR  directory for Unix sockets (default: /tmp)
#   SOCAT_BUF transfer buffer size in bytes (default: 8192)
#
# Performance notes:
# >> publishers note:
# >> The first two sentences come from limited testing.
# >> All the rest is AI conjecture.
#
#   - TCP bridging works well and is the recommended mode.
#   - UDP bridging is functional but limited: socat's UDP fork behavior is
#     not truly connection-oriented, so packets from the same flow may not
#     reliably reach the same forked child, causing loss and reordering.
#   - TCP-over-UDP tunnels (e.g. over WireGuard) suffer from TCP's congestion
#     control reacting to UDP's natural loss, causing severe throughput drops.
#     This is a fundamental protocol mismatch, not a socat or buffer size issue.
#   - Buffer sizes (-b flag) only help on clean lossless links; they do not
#     fix congestion control misbehavior in lossy or encapsulated tunnels.
#   - If using WireGuard, ensure the MTU is set correctly (typically 1420 for
#     IPv4) to avoid fragmentation. Verify with: ping -M do -s <size> <peer>
#     and find the largest size that passes cleanly.

if [ $# -lt 1 ]; then
    echo "Usage: $0 name:port|port:name|port:port[/tcp|/udp] [...]"
    exit 1
fi

# Directory for Unix sockets, override with SOCK_DIR env variable
if [[ -z "$SOCK_DIR" ]]; then
    SOCK_DIR=/tmp
fi

# Create the socket directory if it doesn't exist
mkdir -p "$SOCK_DIR" || { echo "Failed to create SOCK_DIR: $SOCK_DIR" >&2; exit 1; }

pids=()

# Clean up child processes on exit (socat removes socket files itself)
cleanup() {
    echo "Shutting down..."
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null
    done
    exit 0
}

trap 'cleanup "$@"' INT TERM

# >> publishers note:
# >> This inline python really supprised me,
# >> but after some contemplation
# >> I found some beauty in it ...
#
# Convert HSV (h=0..359, s=0..1, v=0..1) to an ANSI 24-bit foreground escape code
hsv_to_ansi() {
    local h=$1 s=$2 v=$3
    python3 -c "
import colorsys, sys
r, g, b = colorsys.hsv_to_rgb($h/360, $s, $v)
r, g, b = int(r*255), int(g*255), int(b*255)
print(f'\033[38;2;{r};{g};{b}m')
"
}

# Run socat and prepend each log line with a colored label
run_socat() {
    local label="$1"
    local color="$2"
    local reset='\033[0m'
    shift 2
    echo "Starting socat [$label]: $*"
    socat -dd -b "${SOCAT_BUF:-8192}" "$@" 2>&1 | awk -v label="$label" -v color="$color" -v reset="$reset" \
        '{ printf "%s[%s]%s %s\n", color, label, reset, $0 }' &
    pids+=($!)
}

for arg in "$@"; do
    # Generate a random hue for this pair, with fixed high saturation and value
    hue=$(( RANDOM % 360 ))
    color=$(hsv_to_ansi "$hue" 0.9 0.95)

    # Split off optional /tcp or /udp suffix
    proto="${arg##*/}"
    if [[ "$proto" == "udp" || "$proto" == "tcp" ]]; then
        pair="${arg%/*}"
    else
        proto="tcp"
        pair="$arg"
    fi
    proto_upper="${proto^^}"

    left="${pair%%:*}"
    right="${pair##*:}"

    if [[ -z "$left" || -z "$right" || "$left" == "$pair" ]]; then
        echo "Invalid pair: '$arg' (expected name:port, port:name, or port:port, with optional /tcp or /udp)" >&2
        continue
    fi

    if [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ ]]; then
        # port:port -> bridge: yank on target port, yeet on source port, socket named after target
        src_port="$left"
        tgt_port="$right"
        name="$tgt_port"
        run_socat "yank:${name}:${tgt_port}/${proto}" "$color" \
            "UNIX-LISTEN:${SOCK_DIR}/${name}.sock,fork,unlink-early" \
            "${proto_upper}:localhost:${tgt_port}"
        run_socat "yeet:${src_port}:${name}/${proto}" "$color" \
            "${proto_upper}-LISTEN:${src_port},fork,reuseaddr" \
            "UNIX-CONNECT:${SOCK_DIR}/${name}.sock"
    elif [[ "$left" =~ ^[0-9]+$ ]]; then
        # port:name -> yeet: listen on TCP/UDP port, forward to Unix socket
        port="$left"
        name="$right"
        run_socat "yeet:${port}:${name}/${proto}" "$color" \
            "${proto_upper}-LISTEN:${port},fork,reuseaddr" \
            "UNIX-CONNECT:${SOCK_DIR}/${name}.sock"
    elif [[ "$right" =~ ^[0-9]+$ ]]; then
        # name:port -> yank: listen on Unix socket, forward to TCP/UDP port
        name="$left"
        port="$right"
        run_socat "yank:${name}:${port}/${proto}" "$color" \
            "UNIX-LISTEN:${SOCK_DIR}/${name}.sock,fork,unlink-early" \
            "${proto_upper}:localhost:${port}"
    else
        echo "Invalid pair: '$arg' (could not determine which side is the port)" >&2
        continue
    fi
done

if [ ${#pids[@]} -eq 0 ]; then
    echo "No valid pairs provided." >&2
    exit 1
fi

echo "All instances started. PIDs: ${pids[*]}"
# Wait for all background socat processes; script stays alive until interrupted
wait
