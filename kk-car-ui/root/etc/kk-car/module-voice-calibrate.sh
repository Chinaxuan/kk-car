#!/bin/sh
set -eu
if ! test -p /run/alsaucm_test; then
    rm -f /run/kkcar-alsaucm.log
    nohup /usr/bin/alsaucm_test </dev/null >/run/kkcar-alsaucm.log 2>&1 &
    n=0
    while ! test -p /run/alsaucm_test; do
        n=$((n + 1))
        test "$n" -lt 50 || { echo 'Calibration service did not start'; exit 2; }
        sleep 0.1
    done
fi
printf 'open snd_soc_msm_9x07_Tomtom_I2S\n' > /run/alsaucm_test
printf 'set _verb VoLTE\n' > /run/alsaucm_test
printf 'set _enadev Auxpcm Rx\n' > /run/alsaucm_test
printf 'set _enadev Auxpcm Tx\n' > /run/alsaucm_test
n=0
while ! grep -q 'ACDB -> Sent VocProc Cal!' /run/kkcar-alsaucm.log 2>/dev/null; do
    n=$((n + 1))
    test "$n" -lt 100 || { echo 'Calibration event not observed'; exit 3; }
    sleep 0.1
done
echo 'VoLTE calibration event observed'
