#!/bin/sh
# Run on an OpenWrt host with ucode, socat and flock. Entire AT peer is mocked;
# no real modem is opened, no real SMS is read, sent or deleted.
set -eu
script=${1:-/etc/kk-car/dji-sms.uc}
dir=$(mktemp -d /tmp/kk-car-sms-fixture.XXXXXX)
peer=
cleanup() {
    [ -z "$peer" ] || kill "$peer" 2>/dev/null || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM
cat > "$dir/mock.sh" <<'EOF'
#!/bin/sh
cr=$(printf '\r')
ctrlz=$(printf '\032')
while IFS= read -r -d "$cr" command; do
    case "$command" in
        'AT+CMGF?') printf '\r\n+CMGF: 0\r\n\r\nOK\r\n' ;;
        'AT+CPMS?') printf '\r\n+CPMS: "ME",23,23,"ME",23,23,"ME",23,23\r\n\r\nOK\r\n' ;;
        'AT+CMGL=4')
            printf '\r\n+CMGL: 1,0,,20\r\n000405810180F6000862904221436500044E2D6587\r\n\r\nOK\r\n' ;;
        'AT+CMGR=1')
            printf '\r\n+CMGR: 0,,20\r\n000405810180F6000862904221436500044E2D6587\r\n\r\nOK\r\n' ;;
        'AT+CMGD=1,0')
            printf '1' > "$KK_CAR_SMS_MOCK_DELETE"
            printf '\r\nOK\r\n' ;;
        'AT+CMGS='*)
            printf '\r\n> '
            IFS= read -r -d "$ctrlz" pdu || true
            printf '%s' "$pdu" > "$KK_CAR_SMS_MOCK_SENT"
            printf '\r\n+CMGS: 7\r\n\r\nOK\r\n' ;;
        *) printf '\r\nERROR\r\n' ;;
    esac
done
EOF
chmod 700 "$dir/mock.sh"
export KK_CAR_SMS_MOCK_DELETE="$dir/deleted" KK_CAR_SMS_MOCK_SENT="$dir/sent"
socat PTY,link="$dir/tty",raw,echo=0 EXEC:"$dir/mock.sh",pty,raw,echo=0 > "$dir/socat.log" 2>&1 & peer=$!
attempt=0
while [ ! -c "$dir/tty" ] && [ "$attempt" -lt 3 ]; do sleep 1; attempt=$((attempt+1)); done
[ -c "$dir/tty" ]
export KK_CAR_SMS_TEST=1 KK_CAR_SMS_TEST_TTY="$dir/tty" KK_CAR_SMS_TEST_SCRIPT="$script"

mkdir -m 700 /tmp/kk-car-dji-sms
mkfifo /tmp/kk-car-dji-sms/input
exec 3<>/tmp/kk-car-dji-sms/input
socat - "$dir/tty",raw,echo=0,b115200 < /tmp/kk-car-dji-sms/input > /tmp/kk-car-dji-sms/response 2>/dev/null & stale=$!
printf '%s' "$stale" > /tmp/kk-car-dji-sms/pid
sleep 1
[ "$(cat "/proc/$stale/comm")" = socat ]
printf '%s' 'old private PDU' > /tmp/kk-car-dji-sms/response

storage=$(ucode "$script" storage)
printf '%s\n' "$storage" | grep -q '"used": 23'
printf '%s\n' "$storage" | grep -q '"capacity": 23'
printf '%s\n' "$storage" | grep -q '"full": true'
[ ! -e /tmp/kk-car-dji-sms/response ]
exec 3>&-
wait "$stale" 2>/dev/null || true

flock -n /tmp/kk-car-dji-at.lock sleep 2 & holder=$!
sleep 1
busy=$(ucode "$script" storage)
printf '%s\n' "$busy" | grep -q '"code": "BUSY"'
wait "$holder"

list=$(ucode "$script" list)
printf '%s\n' "$list" | grep -q '"index": 1'
printf '%s\n' "$list" | grep -q '"from": "10086"'
if printf '%s\n' "$list" | grep -q '中文'; then exit 1; fi

read=$(ucode "$script" read 1)
printf '%s\n' "$read" | grep -q '"text": "中文"'

printf '%s' '{"to":"10086","text":"中文"}' > "$dir/request.json"
chmod 600 "$dir/request.json"
send=$(ucode "$script" send "$dir/request.json")
printf '%s\n' "$send" | grep -q '"reference": 7'
[ "$(cat "$dir/sent")" = '00010005810180F60008044E2D6587' ]

delete=$(ucode "$script" delete 1)
printf '%s\n' "$delete" | grep -q '"ok": true'
[ "$(cat "$dir/deleted")" = 1 ]

printf '%s' '{"to":"10086\rAT+CFUN=1","text":"abc"}' > "$dir/request.json"
invalid=$(ucode "$script" send "$dir/request.json")
printf '%s\n' "$invalid" | grep -q '"code": "INPUT"'

invalid=$(ucode "$script" delete '1;AT+CFUN=1')
printf '%s\n' "$invalid" | grep -q '"code": "INPUT"'

printf '%s' '{"to":"10086","text":"😀"}' > "$dir/request.json"
invalid=$(ucode "$script" send "$dir/request.json")
printf '%s\n' "$invalid" | grep -q '"code": "INPUT"'

printf '%s\n' 'mock serial SMS: PASS'
