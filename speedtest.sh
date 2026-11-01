#!/bin/sh

export LC_ALL=C

# Config
TEST_TIME=5           # Test duration in seconds (-t)
PARALLEL_STREAMS=4    # Parallel streams (-P)
BUSY_RETRIES=2        # Retry attempts on busy server
RETRY_DELAY=5         # Delay between retries in seconds
CONNECT_TIMEOUT=3     # Connection timeout in seconds
TOTAL_TIMEOUT=$(( CONNECT_TIMEOUT + TEST_TIME + 2 ))  # Total test timeout in seconds

FIRST_ONLY=0
while getopts "f" opt; do
    case "$opt" in
        f) FIRST_ONLY=1 ;;
        *) printf "Usage: %s [-f]\n" "$0" >&2; exit 1 ;;
    esac
done

# Format: "Name|Host|Port(s)"
SERVERS_RU="
Hostkey Moscow|spd-rudp.hostkey.ru|5201-5209
MTS Moscow|mskst.st.mtsws.net|3333
Ertelecom Saint Petersburg|st.spb.ertelecom.ru|5201-5209
Ertelecom Rostov-on-Don|st.rostov.ertelecom.ru|5201-5209
Ertelecom Novosibirsk|st.nsk.ertelecom.ru|5201-5209
"

SERVERS_EU="
Hostkey Germany|spd-desrv.hostkey.com|5201-5209
LeaseWeb Netherlands|speedtest.ams1.nl.leaseweb.net|5201-5210
LeaseWeb UK|speedtest.lon12.uk.leaseweb.net|5201-5210
Hostkey Finland|spd-fisrv.hostkey.com|5201-5209
Scaleway France|iperf.online.net|5200-5209
"

SERVERS_US="
Clouvider Ashburn|ash.speedtest.clouvider.net|5200-5209
LeaseWeb Miami|speedtest.mia11.us.leaseweb.net|5201-5210
Clouvider Los Angeles|la.speedtest.clouvider.net|5200-5209
LeaseWeb Seattle|speedtest.sea11.us.leaseweb.net|5201-5210
Clouvider Dallas|dal.speedtest.clouvider.net|5200-5209
"

if ! command -v iperf3 >/dev/null 2>&1; then
    printf "iperf3 not found. Install? [Y/n]: "
    read -r ans
    case "$ans" in [nN]*) echo "Installation cancelled." >&2; exit 1 ;; esac

    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: root privileges required." >&2
        exit 1
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add iperf3
    elif command -v apt-get >/dev/null 2>&1; then
        echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections 2>/dev/null
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3
    else
        echo "Error: unsupported package manager (apt or apk required)." >&2
        exit 1
    fi

    command -v iperf3 >/dev/null 2>&1 || { echo "Error: failed to install iperf3." >&2; exit 1; }
fi

TABLE=""
MAX_NAME_W=6
CLR=$(printf '\033[K')

print_table() {
    if [ -n "$TABLE" ]; then
        w=$(( MAX_NAME_W + 2 ))
        printf "%-${w}s %-17s %-17s %-10s\n" "Server" "Download" "Upload" "Ping"
        while IFS='|' read -r name dl ul ping; do
            [ -n "$name" ] && printf "%-${w}s %-17s %-17s %-10s\n" "$name" "$dl" "$ul" "$ping"
        done <<EOF
$TABLE
EOF
    fi
}

trap 'printf "\n" >&2; [ -n "$TABLE" ] && printf "\n" >&2; print_table; exit 130' INT

run_with_timeout() {
    tout="$1"; shift
    (
        "$@" & c_pid=$!
        (
            trap 'kill "$s_pid" 2>/dev/null; exit 0' TERM
            sleep "$tout" & s_pid=$!
            wait "$s_pid" 2>/dev/null && kill -9 "$c_pid"
        ) >/dev/null 2>&1 & w_pid=$!

        trap 'kill -9 "$c_pid" "$w_pid" 2>/dev/null; exit 130' INT TERM
        wait "$c_pid" 2>/dev/null
        ret=$?
        kill "$w_pid" 2>/dev/null
        [ "$ret" -eq 137 ] && echo "timed out"
        exit "$ret"
    )
}

# Rotate port range with random offset to balance server load
get_ports() {
    case "$1" in
        *-*)
            s="${1%-*}"; e="${1#*-}"; total=$(( e - s + 1 ))
            rnd=$(( $$ % total ))
            i=0; while [ "$i" -lt "$total" ]; do
                printf "%s " "$(( s + (rnd + i) % total ))"
                i=$(( i + 1 ))
            done
            ;;
        *) echo "$1" ;;
    esac
}

get_ping() {
    out=$(ping -c 3 -W 2 "$1" 2>/dev/null)
    val=$(printf '%s\n' "$out" | awk -F'=' '/(rtt|round-trip)/ { split($2, a, "/"); printf "%.1f ms", a[2] }')
    echo "${val:-—}"
}

# Exit codes: 0 = ok, 1 = error, 2 = busy, 3 = timeout
run_transfer() {
    dir="$1"; host="$2"; port="$3"; flags="$4"

    run_with_timeout "$TOTAL_TIMEOUT" iperf3 -c "$host" -p "$port" -t "$TEST_TIME" \
        -P "$PARALLEL_STREAMS" -i 1 --connect-timeout "$(( CONNECT_TIMEOUT * 1000 ))" \
        --forceflush $flags 2>&1 | {
        set -f
        final="" st=1

        while IFS= read -r line; do
            case "$line" in
                *busy*)      st=2 ;;
                *timed*out*) st=3 ;;
                *bits/sec*)
                    [ "$PARALLEL_STREAMS" -gt 1 ] && case "$line" in *"[SUM]"*) ;; *) continue ;; esac
                    set -- ${line#*Bytes}; speed="$1 $2"
                    case "$line" in
                        *receiver*) final="$speed" ;;
                        *sender*)   ;;
                        *)          printf "\r%s: %s%s" "$dir" "$speed" "$CLR" >&2 ;;
                    esac
                    ;;
            esac
        done

        if [ "$st" -eq 3 ]; then
            printf "timeout"; exit 3
        elif [ "$st" -eq 2 ]; then
            printf "server busy"; exit 2
        elif [ -n "$final" ]; then
            printf "\r%s: %s%s\n" "$dir" "$final" "$CLR" >&2
            printf "%s" "$final"; exit 0
        else
            printf "error"; exit 1
        fi
    }
}

test_direction() {
    direction="$1"; host="$2"; ports="$3"; flags="$4"
    round=0

    while [ "$round" -le "$BUSY_RETRIES" ]; do
        busy=0
        for p in $ports; do
            printf "\r%s: connecting (port %s)...%s" "$direction" "$p" "$CLR" >&2
            LAST_SPEED=$(run_transfer "$direction" "$host" "$p" "$flags")
            case $? in
                0) ACTIVE_PORT="$p"; return 0 ;;
                2) busy=1 ;;
                3) break ;;
            esac
        done

        if [ "$busy" -eq 1 ] && [ "$round" -lt "$BUSY_RETRIES" ]; then
            printf "\r%s: server busy, retrying in %ss...%s" "$direction" "$RETRY_DELAY" "$CLR" >&2
            sleep "$RETRY_DELAY"
            round=$(( round + 1 ))
        else
            [ "$busy" -eq 1 ] && LAST_SPEED="server busy"
            printf "\r%s: %s%s\n" "$direction" "$LAST_SPEED" "$CLR" >&2
            return 1
        fi
    done
    return 1
}

test_server() {
    name="$1"; host="$2"; ports="$3"
    printf "%s\n" "$name" >&2

    printf "\rPing: testing...%s" "$CLR" >&2
    ping_val=$(get_ping "$host")
    printf "\rPing: %s%s\n" "$ping_val" "$CLR" >&2

    port_list=$(get_ports "$ports")

    if test_direction "Download" "$host" "$port_list" "-R"; then
        dl_val="$LAST_SPEED"
        ul_ports="$ACTIVE_PORT"
        for p in $port_list; do
            [ "$p" != "$ACTIVE_PORT" ] && ul_ports="$ul_ports $p"
        done

        if test_direction "Upload" "$host" "$ul_ports" ""; then
            TABLE="${TABLE}${name}|${dl_val}|${LAST_SPEED}|${ping_val}
"
            [ "${#name}" -gt "$MAX_NAME_W" ] && MAX_NAME_W="${#name}"
        fi
    else
        printf "Upload: skipped\n" >&2
    fi
    printf "\n" >&2
}

# Main
while :; do
    printf "Select region:\n  1) Russia\n  2) Europe\n  3) USA\nChoice [1]: "
    read -r region || exit 1
    case "$region" in
        ""|1) SERVERS="$SERVERS_RU"; break ;;
        2)    SERVERS="$SERVERS_EU"; break ;;
        3)    SERVERS="$SERVERS_US"; break ;;
        *)    printf "Invalid input, please try again.\n\n" >&2 ;;
    esac
done
printf "\n" >&2

while IFS='|' read -r name host ports; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    test_server "$name" "$host" "$ports"
    [ "$FIRST_ONLY" -eq 1 ] && break
done <<EOF
$SERVERS
EOF

print_table