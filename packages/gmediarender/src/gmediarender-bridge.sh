#!/bin/bash
#
# gmediarender-bridge.sh - Metadata bridge between gmrender-resurrect and ACR
#
# Reads gmrender-resurrect's log output on stdin and sends state/metadata
# updates to ACR's generic player API via HTTP POST.
#
# gmrender-resurrect logs lines like:
#   TransportState: PLAYING
#   TransportState: PAUSED_PLAYBACK
#   TransportState: STOPPED
#   TransportState: NO_MEDIA_PRESENT
#   CurrentTrackMetaData: <DIDL-Lite ...>
#   AVTransportURI: http://...
#   CurrentTrackDuration: 0:03:45
#
# We translate these into ACR generic player events.
#

ACR_URL="http://localhost:1080/api/player/dlna/update"
LOG_FILE="/tmp/gmediarender.log"

# Track current state to avoid duplicate updates
CURRENT_STATE=""

# Post an event to ACR. Silently ignore failures (ACR might not be running).
post_event() {
    local payload="$1"
    curl -sf -X POST "$ACR_URL" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        --connect-timeout 2 \
        --max-time 5 \
        >/dev/null 2>&1 || true
}

# Map UPnP transport state to ACR state
map_state() {
    case "$1" in
        PLAYING)            echo "playing" ;;
        PAUSED_PLAYBACK)    echo "paused" ;;
        STOPPED)            echo "stopped" ;;
        NO_MEDIA_PRESENT)   echo "stopped" ;;
        TRANSITIONING)      echo "unknown" ;;
        *)                  echo "" ;;
    esac
}

# Parse a duration string (H:MM:SS or HH:MM:SS) to seconds
parse_duration() {
    local dur="$1"
    local h m s
    IFS=: read -r h m s <<< "$dur"
    # Strip leading zeros to avoid octal interpretation
    h=$((10#$h))
    m=$((10#$m))
    s=$((10#$s))
    echo $(( h * 3600 + m * 60 + s ))
}

# Escape a string for safe JSON embedding
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

# Extract a value from DIDL-Lite XML using simple pattern matching.
# Not a full XML parser, but sufficient for the well-structured DIDL-Lite
# that UPnP controllers send.
extract_didl_field() {
    local xml="$1"
    local tag="$2"
    # Match <tag ...>value</tag> — handles namespace prefixes like dc:title
    echo "$xml" | grep -oP "<${tag}[^>]*>\K[^<]*" | head -1
}

# Variables to accumulate metadata from DIDL-Lite
META_TITLE=""
META_ARTIST=""
META_ALBUM=""
META_DURATION=""

# Process each line of gmrender-resurrect output
while IFS= read -r line; do
    # Log all output for debugging
    echo "$line" >> "$LOG_FILE"

    # Handle transport state changes
    if [[ "$line" =~ ^TransportState:\ *(.+)$ ]]; then
        upnp_state="${BASH_REMATCH[1]}"
        upnp_state="${upnp_state%% *}"  # trim trailing whitespace
        acr_state=$(map_state "$upnp_state")

        if [ -n "$acr_state" ] && [ "$acr_state" != "$CURRENT_STATE" ]; then
            CURRENT_STATE="$acr_state"
            post_event "{\"type\":\"state_changed\",\"state\":\"$acr_state\"}"
        fi
    fi

    # Handle track duration
    if [[ "$line" =~ ^CurrentTrackDuration:\ *([0-9]+:[0-9]+:[0-9]+) ]]; then
        META_DURATION=$(parse_duration "${BASH_REMATCH[1]}")
    fi

    # Handle DIDL-Lite metadata (may arrive on a single long line)
    if [[ "$line" =~ CurrentTrackMetaData:\ *(.+) ]]; then
        didl="${BASH_REMATCH[1]}"

        title=$(extract_didl_field "$didl" "dc:title")
        artist=$(extract_didl_field "$didl" "dc:creator")
        album=$(extract_didl_field "$didl" "upnp:album")

        # Also try r:albumArtist or upnp:artist as fallbacks
        if [ -z "$artist" ]; then
            artist=$(extract_didl_field "$didl" "upnp:artist")
        fi

        # Only send song_changed if we got at least a title
        if [ -n "$title" ]; then
            META_TITLE=$(json_escape "$title")
            META_ARTIST=$(json_escape "${artist:-}")
            META_ALBUM=$(json_escape "${album:-}")

            song_json="{\"type\":\"song_changed\",\"song\":{"
            song_json+="\"title\":\"$META_TITLE\""
            song_json+=",\"artist\":\"$META_ARTIST\""
            song_json+=",\"album\":\"$META_ALBUM\""
            if [ -n "$META_DURATION" ] && [ "$META_DURATION" -gt 0 ] 2>/dev/null; then
                song_json+=",\"duration\":$META_DURATION"
            fi
            song_json+="}}"

            post_event "$song_json"
        fi
    fi

    # Handle AVTransportURI — when a new track is being set up but before
    # DIDL-Lite metadata arrives, we can at least log the URI
    if [[ "$line" =~ ^AVTransportURI:\ *(.+)$ ]]; then
        transport_uri="${BASH_REMATCH[1]}"
        echo "New transport URI: $transport_uri" >> "$LOG_FILE"
    fi

done
