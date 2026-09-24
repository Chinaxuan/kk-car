#!/bin/sh
# Run on OpenWrt. All phone data stays in an isolated disposable /tmp fixture.
set -eu
source_file=${1:-/etc/kk-car/dji-phonebook.uc}
test_dir=$(mktemp -d /tmp/kk-car-phone-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT INT TERM
sed -e "s@/etc/kk-car/private/dji-phonebook.json@$test_dir/phone.json@g" \
    -e "s@/tmp/kk-car-dji-phonebook.lock@$test_dir/lock@g" \
    "$source_file" > "$test_dir/phonebook.uc"
cat > "$test_dir/test.uc" <<EOF
import {observe,seed_outgoing,get_data,save_contact,delete_contact} from '$test_dir/phonebook.uc';
import {stat} from 'fs';
function check(ok,label){if(!ok)die('FAIL '+label+'\\n');}
check(observe({ok:true,state:'来电振铃',direction:'incoming',count:1,number:'15500000000'}),'ring');
check(observe({ok:true,state:'idle',count:0}),'idle');
let d=get_data();
check(length(d.history)==1 && d.history[0].kind=='未接' && d.history[0].number=='15500000000','missed record');
check(seed_outgoing('15500000001'),'outgoing seed');
check(observe({ok:true,state:'通话中',direction:'outgoing',count:1}),'connected');
check(observe({ok:true,state:'idle',count:0}),'hangup');
d=get_data();
check(length(d.history)==2 && d.history[0].kind=='已拨' && d.history[0].number=='15500000001','outgoing record');
check(save_contact('测试','15500000001').ok,'save contact');
check(length(get_data().contacts)==1,'contact persisted');
check(delete_contact('15500000001').ok && length(get_data().contacts)==0,'delete contact');
check(!save_contact('','15500000001').ok && !save_contact('测试','bad').ok,'reject invalid contact');
let file=stat('$test_dir/phone.json');
check(file && !file.perm.group_read && !file.perm.group_write && !file.perm.other_read && !file.perm.other_write,'private permissions');
printf('PASS phone history and contacts\\n');
EOF
ucode "$test_dir/test.uc"
