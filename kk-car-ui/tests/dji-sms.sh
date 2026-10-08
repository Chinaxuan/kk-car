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
        'AT+CPMS?') printf '\r\n+CPMS: "SM",23,40,"SM",23,40,"SM",23,40\r\n\r\nOK\r\n' ;;
        'AT+CPMS=?') printf '\r\n+CPMS: ("ME","SM"),("ME","SM"),("ME","SM")\r\n\r\nOK\r\n' ;;
        'AT+CNMI?') printf '\r\n+CNMI: 2,1,0,0,0\r\n\r\nOK\r\n' ;;
        'AT+QGPS?')
            if [ -f "$KK_CAR_SMS_MOCK_GPS" ]; then printf '\r\n+QGPS: 1\r\n\r\nOK\r\n';
            else printf '\r\n+QGPS: 0\r\n\r\nOK\r\n'; fi ;;
        'AT+QGPS=1') : > "$KK_CAR_SMS_MOCK_GPS"; printf '\r\nOK\r\n' ;;
        'AT+QGPSEND') rm -f "$KK_CAR_SMS_MOCK_GPS"; printf '\r\nOK\r\n' ;;
        'AT+QGPSGNMEA="GSV"') printf '\r\n+QGPSGNMEA: $GPGSV,1,1,04,38,50,120,34,40,35,220,34,41,65,080,35,50,42,310,34,1*00\r\n\r\nOK\r\n' ;;
        'AT+QGPSGNMEA="GSA"')
            if [ -f "$KK_CAR_SMS_MOCK_NOFIX" ]; then printf '\r\n+QGPSGNMEA: $GPGSA,A,1,,,,,,,,,,,,,,,,*32\r\n\r\nOK\r\n';
            else printf '\r\n+QGPSGNMEA: $GPGSA,A,3,38,40,41,50,,,,,,,,,1.8,0.9,1.6*00\r\n\r\nOK\r\n'; fi ;;
        'AT+QGPSLOC=2')
            if [ -f "$KK_CAR_SMS_MOCK_NOFIX" ]; then printf '\r\n+CME ERROR: 516\r\n';
            else printf '\r\n+QGPSLOC: 061951.0,31.84537,117.19882,0.7,62.2,3,0.0,45.5,24.5,110513,09\r\n\r\nOK\r\n'; fi ;;
        'AT+CLCC') printf '\r\n+CLCC: 1,1,0,1,1,"",128\r\n+CLCC: 2,1,4,0,0\r\n\r\nOK\r\n' ;;
        'AT+QCFG="usbcfg"') printf '\r\n+QCFG: "usbcfg",11308,293,1,1,1,1,1,0,0\r\n\r\nOK\r\n' ;;
        'AT+QCFG="ims"') printf '\r\n+QCFG: "ims",0\r\n\r\nOK\r\n' ;;
        'AT+CMGL=4')
            printf '\r\n+CMGL: 1,0,,20\r\n000405810180F6000862904221436500044E2D6587\r\n+CMGL: 2,0,,25\r\n004405810180F6000862904221436500080500037A02014E2D\r\n+CMGL: 3,0,,25\r\n004405810180F6000862904221436500080500037A02026587\r\n+CMGL: 4,0,,26\r\n004405810180F600086290422143650009060804123402014E2D\r\n+CMGL: 5,0,,26\r\n004405810180F600086290422143650009060804123402026587\r\n\r\nOK\r\n' ;;
        'AT+CMGR=1')
            printf '\r\n+CMGR: 0,,20\r\n000405810180F6000862904221436500044E2D6587\r\n\r\nOK\r\n' ;;
        'AT+CMGR=2')
            printf '\r\n+CMGR: 0,,25\r\n004405810180F6000862904221436500080500037A02014E2D\r\n\r\nOK\r\n' ;;
        'AT+CMGR=3')
            printf '\r\n+CMGR: 0,,25\r\n004405810180F6000862904221436500080500037A02026587\r\n\r\nOK\r\n' ;;
        'AT+CMGR=4')
            printf '\r\n+CMGR: 0,,26\r\n004405810180F600086290422143650009060804123402014E2D\r\n\r\nOK\r\n' ;;
        'AT+CMGR=5')
            printf '\r\n+CMGR: 0,,26\r\n004405810180F600086290422143650009060804123402026587\r\n\r\nOK\r\n' ;;
        'AT+CMGD=1,0')
            printf '1' > "$KK_CAR_SMS_MOCK_DELETE"
            printf '\r\nOK\r\n' ;;
        'AT+CMGD=2,0'|'AT+CMGD=3,0')
            printf '%s' "${command#AT+CMGD=}" | cut -d, -f1 >> "$KK_CAR_SMS_MOCK_DELETE"
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
export KK_CAR_SMS_MOCK_DELETE="$dir/deleted" KK_CAR_SMS_MOCK_SENT="$dir/sent" KK_CAR_SMS_MOCK_GPS="$dir/gps-on" KK_CAR_SMS_MOCK_NOFIX="$dir/gps-nofix"
export KK_CAR_SMS_TEST_WORK="$dir/work"
socat PTY,link="$dir/tty",raw,echo=0 EXEC:"$dir/mock.sh",pty,raw,echo=0 > "$dir/socat.log" 2>&1 & peer=$!
attempt=0
while [ ! -c "$dir/tty" ] && [ "$attempt" -lt 3 ]; do sleep 1; attempt=$((attempt+1)); done
[ -c "$dir/tty" ]
export KK_CAR_SMS_TEST=1 KK_CAR_SMS_TEST_TTY="$dir/tty" KK_CAR_SMS_TEST_SCRIPT="$script"

mkdir -m 700 "$KK_CAR_SMS_TEST_WORK"
mkfifo "$KK_CAR_SMS_TEST_WORK/input"
exec 3<>"$KK_CAR_SMS_TEST_WORK/input"
socat - "$dir/tty",raw,echo=0,b115200 < "$KK_CAR_SMS_TEST_WORK/input" > "$KK_CAR_SMS_TEST_WORK/response" 2>/dev/null & stale=$!
printf '%s' "$stale" > "$KK_CAR_SMS_TEST_WORK/pid"
sleep 1
[ "$(cat "/proc/$stale/comm")" = socat ]
printf '%s' 'old private PDU' > "$KK_CAR_SMS_TEST_WORK/response"

storage=$(ucode "$script" storage)
printf '%s\n' "$storage" | grep -q '"used": 23'
printf '%s\n' "$storage" | grep -q '"capacity": 40'
printf '%s\n' "$storage" | grep -q '"full": false'
[ ! -e "$KK_CAR_SMS_TEST_WORK/response" ]
probe=$(ucode "$script" storage_probe)
printf '%s\n' "$probe" | grep -q '"sim_receive": true'
printf '%s\n' "$probe" | grep -q '"incoming_mode": 1'
exec 3>&-
wait "$stale" 2>/dev/null || true

flock -n /tmp/kk-car-dji-at-test.lock sleep 2 & holder=$!
sleep 1
busy=$(ucode "$script" storage)
printf '%s\n' "$busy" | grep -q '"code": "BUSY"'
wait "$holder"

list=$(ucode "$script" list)
printf '%s\n' "$list" | grep -q '"index": 1'
printf '%s\n' "$list" | grep -q '"from": "10086"'
printf '%s\n' "$list" | grep -q '"conversation_count": 3'
printf '%s\n' "$list" | grep -q '"complete": true'
printf '%s\n' "$list" | grep -q '"ref": 122'
printf '%s\n' "$list" | grep -q '"ref": 4660'
if printf '%s\n' "$list" | grep -q '中文'; then exit 1; fi

read=$(ucode "$script" read 1)
printf '%s\n' "$read" | grep -q '"text": "中文"'
read=$(ucode "$script" read 2)
printf '%s\n' "$read" | grep -q '"text": "中"'
printf '%s\n' "$read" | grep -q '"part": 1'
read=$(ucode "$script" read 3)
printf '%s\n' "$read" | grep -q '"text": "文"'
printf '%s\n' "$read" | grep -q '"part": 2'
read=$(ucode "$script" read 4)
printf '%s\n' "$read" | grep -q '"bits": 16'
printf '%s\n' "$read" | grep -q '"part": 1'
read=$(ucode "$script" read 5)
printf '%s\n' "$read" | grep -q '"bits": 16'
printf '%s\n' "$read" | grep -q '"part": 2'

sms_time=$(printf '%s\n' "$list" | jsonfilter -e '@.groups[0].time')
sms_digest=$(printf '中文' | sha256sum | cut -d' ' -f1)
printf '{"id":"%064d","index":1,"parts":[1],"from":"10086","time":"%s","concat":null,"digest":"%064d"}' 0 "$sms_time" 0 > "$dir/request.json"
chmod 600 "$dir/request.json"
invalid=$(ucode "$script" cleanup "$dir/request.json")
printf '%s\n' "$invalid" | grep -q '"code": "CHANGED"'
[ ! -e "$KK_CAR_SMS_MOCK_DELETE" ]
printf '{"id":"%064d","index":1,"parts":[1],"from":"10086","time":"%s","concat":null,"digest":"%s"}' 0 "$sms_time" "$sms_digest" > "$dir/request.json"
cleared=$(ucode "$script" cleanup "$dir/request.json")
printf '%s\n' "$cleared" | grep -q '"removed": 1'
[ "$(cat "$KK_CAR_SMS_MOCK_DELETE")" = 1 ]
rm -f "$KK_CAR_SMS_MOCK_DELETE"
long_digest=$(printf '中文' | sha256sum | cut -d' ' -f1)
printf '{"id":"%064d","index":2,"parts":[2,3],"from":"10086","time":"%s","concat":{"ref":122,"bits":8,"total":2},"digest":"%s"}' 0 "$sms_time" "$long_digest" > "$dir/request.json"
long_result=$(ucode "$script" cleanup "$dir/request.json")
printf '%s\n' "$long_result" | grep -q '"removed": 2'
[ "$(tr -d '\n' < "$KK_CAR_SMS_MOCK_DELETE")" = 32 ]
rm -f "$KK_CAR_SMS_MOCK_DELETE"

call=$(ucode "$script" call_status)
printf '%s\n' "$call" | grep -q '"state": "来电振铃"'
printf '%s\n' "$call" | grep -q '"count": 1'
if printf '%s\n' "$call" | grep -q '12345678901'; then exit 1; fi
voice=$(ucode "$script" voice_probe)
printf '%s\n' "$voice" | grep -q '"active_calls": 1'
printf '%s\n' "$voice" | grep -q '"usb_voice_enabled": false'
gps=$(ucode "$script" gps_probe)
printf '%s\n' "$gps" | grep -q '"enabled": false'
gps=$(ucode "$script" gps_start)
printf '%s\n' "$gps" | grep -q '"fix": true'
printf '%s\n' "$gps" | grep -q '"speed_kmh": 45.5'
printf '%s\n' "$gps" | grep -q '"visible_count": 4'
printf '%s\n' "$gps" | grep -q '"used_count": 4'
printf '%s\n' "$gps" | grep -q '"strongest_cn0_dbhz": 35'
printf '%s\n' "$gps" | grep -q '"altitude_m": 62.2'
: > "$KK_CAR_SMS_MOCK_NOFIX"
gps=$(ucode "$script" gps_probe)
printf '%s\n' "$gps" | grep -q '"fix": false'
printf '%s\n' "$gps" | grep -q '"visible_count": 4'
printf '%s\n' "$gps" | grep -q '"used_count": 0'
printf '%s\n' "$gps" | grep -q '"fix_mode": 1'
gps=$(ucode "$script" gps_stop)
printf '%s\n' "$gps" | grep -q '"enabled": false'

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
