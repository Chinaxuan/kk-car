#!/bin/sh
# Read-only DJI/Quectel AT telemetry. Never emit raw replies: serving-cell
# replies contain location identifiers, even when only signal data is needed.
umask 077
sysfs=${KK_CAR_SYSFS_ROOT:-/sys}
devroot=${KK_CAR_DEV_ROOT:-/dev}
lock=${KK_CAR_DJI_AT_LOCK:-/tmp/kk-car-dji-at.lock}

usb_parent() {
    node=$1
    while [ "$node" != / ] && [ -n "$node" ]; do
        if [ -f "$node/idVendor" ] && [ -f "$node/idProduct" ]; then
            printf '%s\n' "$node"
            return 0
        fi
        node=${node%/*}
    done
    return 1
}

port=
for tty in "$sysfs"/class/tty/ttyUSB*; do
    [ -e "$tty/device" ] || continue
    tty_node=$(readlink -f "$tty/device" 2>/dev/null) || continue
    interface=${tty_node%/*}
    [ "$(cat "$interface/bInterfaceNumber" 2>/dev/null)" = 02 ] || continue
    driver=$(readlink -f "$interface/driver" 2>/dev/null)
    case "${driver##*/}" in option|qcserial) ;; *) continue ;; esac
    usb=$(usb_parent "$interface") || continue
    vid=$(cat "$usb/idVendor" 2>/dev/null)
    pid=$(cat "$usb/idProduct" 2>/dev/null)
    case "$vid:$pid" in 2ca3:4006|2c7c:0125) ;; *) continue ;; esac
    candidate="$devroot/${tty##*/}"
    [ -c "$candidate" ] || continue
    port=$candidate
    break
done
[ -n "$port" ] || exit 3
command -v socat >/dev/null 2>&1 || exit 1
command -v flock >/dev/null 2>&1 || exit 1

# A separate SMS backend uses the same lock. Busy readers fail fast and let
# the next telemetry refresh try again; they never interrupt an SMS action.
exec 9>"$lock" || exit 1
flock -n 9 || exit 4

run_dir=$(mktemp -d /tmp/kk-car-dji-at.XXXXXX) || exit 1
reply_pipe=$run_dir/reply
mkfifo "$reply_pipe" || { rmdir "$run_dir"; exit 1; }
active= timer=
cleanup() {
    [ -z "$active" ] || kill "$active" 2>/dev/null
    [ -z "$timer" ] || kill "$timer" 2>/dev/null
    rm -f "$reply_pipe"
    rmdir "$run_dir" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 143' TERM INT

send_queries() {
    for cmd in 'ATI' 'AT+CPIN?' 'AT+QNWINFO' 'AT+QENG="servingcell"' 'AT+QENG="neighbourcell"' 'AT+QTEMP' 'AT+QGPS?'; do
        printf '%s\r' "$cmd"
        sleep 1
    done
}
# The FIFO holds no reply data on disk. The watchdog also bounds an ongoing
# stream of unsolicited modem messages, which socat -T alone cannot do.
send_queries | socat -T 3 - "$port",raw,echo=0,b115200 > "$reply_pipe" 2>/dev/null & active=$!
(
    delay=
    trap '[ -z "$delay" ] || kill "$delay" 2>/dev/null; exit 0' TERM INT
    sleep 12 & delay=$!
    wait "$delay" 2>/dev/null
    kill "$active" 2>/dev/null
    sleep 1 & delay=$!
    wait "$delay" 2>/dev/null
    kill -9 "$active" 2>/dev/null
) & timer=$!
result=$(tr -d '\r' < "$reply_pipe" | awk -v now="$(date +%s)" '
function string_json(s) { return s == "" ? "null" : "\"" s "\"" }
function number_json(s, lo, hi) {
    gsub(/[[:space:]]/, "", s)
    return s ~ /^-?[0-9]+([.][0-9]+)?$/ && s + 0 >= lo && s + 0 <= hi ? s : "null"
}
/^Revision:[[:space:]]*/ {
    firmware = $0
    sub(/^Revision:[[:space:]]*/, "", firmware)
    gsub(/[^A-Za-z0-9._-]/, "", firmware)
    firmware = substr(firmware, 1, 64)
}
/^\+QNWINFO:/ {
    split($0, nw, "\"")
    if (nw[2] ~ /^(FDD LTE|TDD LTE|LTE|WCDMA|GSM|EDGE|HSPA|HSPA[+]?)$/)
        technology = nw[2]
    if (nw[6] ~ /^LTE BAND [0-9]+$/) {
        band = nw[6]
        sub(/^LTE BAND /, "LTE B", band)
    }
}
/^\+QENG:[[:space:]]*"servingcell"/ {
    n = split($0, cell, ",")
    if (n >= 17 && cell[3] ~ /"LTE"/) {
        if (technology == "") technology = "LTE"
        if (band == "" && cell[10] ~ /^[0-9]+$/ && cell[10] + 0 >= 1 && cell[10] + 0 <= 88)
            band = "LTE B" cell[10]
        if (cell[2] ~ /^[[:space:]]*"(NOCONN|CONNECT|LIMSRV|SEARCH)"[[:space:]]*$/)
            registration = cell[2]
        gsub(/"/, "", registration)
        gsub(/[[:space:]]/, "", registration)
        rsrp = number_json(cell[14], -160, -30)
        rsrq = number_json(cell[15], -35, 5)
        rssi = number_json(cell[16], -130, -20)
        sinr = number_json(cell[17], -30, 50)
    }
}
/^\+QENG:[[:space:]]*"neighbourcell (intra|inter)","LTE",/ {
    # Keep only aggregate radio quality. EARFCN and PCI can identify the
    # serving area, so neither the original line nor those fields leave awk.
    n = split($0, neighbour, ",")
    if (n < 8 || neighbour[3] !~ /^[0-9]+$/ || neighbour[4] !~ /^[0-9]+$/)
        next
    quality = number_json(neighbour[5], -35, 5)
    power = number_json(neighbour[6], -160, -30)
    if (quality == "null" || power == "null") next
    if (neighbour[1] ~ /"neighbourcell intra"/) intra_count++
    else if (neighbour[1] ~ /"neighbourcell inter"/) inter_count++
    else next
    if (best_neighbour_rsrp == "" || power + 0 > best_neighbour_rsrp + 0)
        best_neighbour_rsrp = power
}
/^\+CPIN:[[:space:]]*/ {
    pin = $0
    sub(/^\+CPIN:[[:space:]]*/, "", pin)
    gsub(/[[:space:]]+$/, "", pin)
    if (pin == "READY") pin_state = "ready"
    else if (pin == "SIM PIN" || pin == "SIM PIN2") pin_state = "pin_required"
    else if (pin == "SIM PUK" || pin == "SIM PUK2") pin_state = "puk_required"
    else if (pin ~ /^[A-Z][A-Z0-9 -]*$/ && length(pin) <= 48) pin_state = "unknown"
}
/^\+QTEMP:[[:space:]]*/ {
    temp = $0
    sub(/^\+QTEMP:[[:space:]]*/, "", temp)
    split(temp, temperatures, ",")
    module_temp = number_json(temperatures[1], -40, 150)
}
/^\+QGPS:[[:space:]]*[01][[:space:]]*$/ {
    gps = $0
    sub(/^\+QGPS:[[:space:]]*/, "", gps)
    gsub(/[[:space:]]/, "", gps)
    gps_enabled = gps == "1" ? "true" : "false"
}
/^OK$/ { ok++ }
END {
    if (!ok) exit 1
    if (module_temp == "") module_temp = "null"
    if (rsrp == "") rsrp = "null"
    if (rsrq == "") rsrq = "null"
    if (rssi == "") rssi = "null"
    if (sinr == "") sinr = "null"
    if (gps_enabled == "") gps_enabled = "null"
    neighbours = intra_count + inter_count > 0 ? sprintf("{\"intra_count\":%d,\"inter_count\":%d,\"best_rsrp_dbm\":%s}", intra_count, inter_count, best_neighbour_rsrp) : "null"
    printf "{\"timestamp\":%d,\"firmware\":%s,\"technology\":%s,\"band\":%s,\"registration\":%s,\"module_temperature_c\":%s,\"gps_enabled\":%s,\"rsrp_dbm\":%s,\"rsrq_db\":%s,\"rssi_dbm\":%s,\"sinr_db\":%s,\"sim_pin_state\":%s,\"neighbours\":%s}\n", now, string_json(firmware), string_json(technology), string_json(band), string_json(registration), module_temp, gps_enabled, rsrp, rsrq, rssi, sinr, string_json(pin_state), neighbours
}')
parse_rc=$?
wait "$active" 2>/dev/null
active=
kill "$timer" 2>/dev/null
wait "$timer" 2>/dev/null
timer=
[ "$parse_rc" -eq 0 ] && [ -n "$result" ] || exit 1
printf '%s\n' "$result"
