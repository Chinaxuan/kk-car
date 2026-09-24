#!/usr/bin/ucode
'use strict';
// DJI/Baiwang QDC507 SMS access. PDU mode keeps the module's CMGF/CSCS/CSMP
// settings unchanged. No message text or phone number is written to logs.
import { access, chmod, glob, mkdir, open, popen, readfile, rmdir, stat, unlink, writefile } from 'fs';

const TEST = getenv('KK_CAR_SMS_TEST') == '1';
const LOCK = TEST ? '/tmp/kk-car-dji-at-test.lock' : '/tmp/kk-car-dji-at.lock';
const TEST_WORK = getenv('KK_CAR_SMS_TEST_WORK') || '';
if (TEST && !match(TEST_WORK, /^\/tmp\/kk-car-sms-fixture\.[A-Za-z0-9]+\/work$/)) exit(2);
const WORK = TEST ? TEST_WORK : '/tmp/kk-car-dji-sms';
const OUT = WORK + '/response';
const FIFO = WORK + '/input';
const PID = WORK + '/pid';

function error(code, message) { return {ok:false, code, error:message}; }
function read_command(cmd) {
    let p = popen(cmd + ' 2>/dev/null');
    if (!p) return '';
    let v = trim(p.read('all') || ''); p.close(); return v;
}
function device() {
    if (TEST) {
        let path = getenv('KK_CAR_SMS_TEST_TTY') || '';
        return match(path, /^\/tmp\/[A-Za-z0-9_./-]+$/) && stat(path)?.type == 'char' ? path : null;
    }
    for (let entry in glob('/sys/class/tty/ttyUSB*')) {
        let name = replace(entry || '', /^.*\//, '');
        if (!match(name || '', /^ttyUSB[0-9]+$/)) continue;
        let tty = read_command('readlink -f /sys/class/tty/' + name + '/device');
        if (!match(tty, /^\/sys\/devices\/[A-Za-z0-9_./:-]+\/ttyUSB[0-9]+$/)) continue;
        let iface = replace(tty, /\/ttyUSB[0-9]+$/, '');
        let usb = replace(iface, /\/[^/]+$/, '');
        if (trim(readfile(iface + '/bInterfaceNumber') || '') != '02') continue;
        if (trim(readfile(usb + '/idVendor') || '') != '2c7c' ||
            trim(readfile(usb + '/idProduct') || '') != '0125') continue;
        if (uc(trim(readfile(usb + '/manufacturer') || '')) != 'BAIWANG') continue;
        if (!match(read_command('readlink -f ' + iface + '/driver'), /\/(option|qcserial)$/)) continue;
        let path = '/dev/' + name;
        if (stat(path)?.type == 'char') return path;
    }
    return null;
}
function stop_owned_socat() {
    let pid = trim(readfile(PID) || '');
    if (!match(pid, /^[0-9]+$/) || trim(readfile('/proc/' + pid + '/comm') || '') != 'socat') return;
    // A reused PID, or another unrelated socat, must never be killed.
    if (read_command('readlink -f /proc/' + pid + '/fd/0') != FIFO ||
        read_command('readlink -f /proc/' + pid + '/fd/1') != OUT) return;
    system('kill ' + pid + ' >/dev/null 2>&1');
}
function clean() {
    stop_owned_socat();
    for (let path in [PID, FIFO, OUT]) unlink(path);
    rmdir(WORK);
}
function clear_stale_work() {
    // The caller already holds the shared flock. A previous killed process may
    // have left a RAM-only response containing raw message PDU behind.
    if (!access(WORK)) return;
    stop_owned_socat();
    for (let path in [PID, FIFO, OUT]) unlink(path);
    rmdir(WORK);
}
function session_start(tty) {
    if (system('command -v socat >/dev/null 2>&1') != 0)
        return error('DEPENDENCY', '缺少串口通信组件');
    clear_stale_work();
    if (!mkdir(WORK, 0700)) return error('BUSY', '短信操作尚未结束');
    if (!writefile(OUT, '\n') || system('mkfifo ' + FIFO + ' >/dev/null 2>&1') != 0) {
        clean(); return error('IO', '无法初始化模块连接');
    }
    chmod(OUT, 0600); chmod(FIFO, 0600);
    // Paths are fixed except tty, which is selected from validated sysfs entries.
    let command = 'sh -c \'socat - ' + tty + ',raw,echo=0,b115200,hupcl=0 < ' + FIFO +
        ' > ' + OUT + ' 2>/dev/null & echo $! > ' + PID + '\'';
    if (system(command) != 0) { clean(); return error('IO', '无法打开模块串口'); }
    // Linux O_RDWR on a FIFO opens immediately, including if socat has died.
    // This keeps an absent helper from indefinitely blocking an RPC worker.
    let writer = open(FIFO, 'r+');
    if (!writer) { clean(); return error('IO', '无法连接模块串口'); }
    return {ok:true, writer};
}
function exchange(session, command, seconds, prompt) {
    let start = length(readfile(OUT) || '');
    if (start > 65536) return error('IO', '模块响应过长');
    if (session.writer.write(command) == null || !session.writer.flush())
        return error('IO', '无法写入模块');
    let deadline = time() + seconds;
    while (time() <= deadline) {
        let all = readfile(OUT) || '';
        if (length(all) > 65536) return error('IO', '模块响应过长');
        let part = substr(all, start);
        if (match(part, /\r?\n\+(CMS|CME) ERROR:\s*[0-9]+\r?\n/) ||
            match(part, /\r?\nERROR\r?\n/)) return error('AT_ERROR', '模块拒绝短信操作');
        if (prompt ? index(part, '> ') >= 0 : match(part, /\r?\nOK\r?\n/))
            return {ok:true, data:part};
        sleep(0.1);
    }
    return error(prompt ? 'PROMPT_TIMEOUT' : 'TIMEOUT', prompt ? '模块未进入短信输入状态' : '模块响应超时');
}
function at(session, command, seconds) { return exchange(session, command + '\r', seconds || 6, false); }
function byte(hex, pos) {
    return pos < 0 || (pos + 1) * 2 > length(hex) ? null : int(substr(hex, pos * 2, 2), 16);
}
function utf8(code) {
    if (code < 0x80) return chr(code);
    if (code < 0x800) return chr(0xc0 | (code >> 6)) + chr(0x80 | (code & 63));
    if (code < 0x10000) return chr(0xe0 | (code >> 12)) + chr(0x80 | ((code >> 6) & 63)) + chr(0x80 | (code & 63));
    return chr(0xf0 | (code >> 18)) + chr(0x80 | ((code >> 12) & 63)) + chr(0x80 | ((code >> 6) & 63)) + chr(0x80 | (code & 63));
}
function ucs2_encode(s) {
    if (type(s) != 'string' || length(s) < 1 || length(s) > 210) return null;
    let result = '', chars = 0;
    for (let i = 0; i < length(s); i++) {
        let a = ord(substr(s, i, 1)), code = null, b = null, c = null;
        if (a < 0x80) code = a;
        else if (a >= 0xc2 && a <= 0xdf && i + 1 < length(s)) {
            b = ord(substr(s, ++i, 1));
            if (b >= 0x80 && b <= 0xbf) code = ((a & 31) << 6) | (b & 63);
        }
        else if (a >= 0xe0 && a <= 0xef && i + 2 < length(s)) {
            b = ord(substr(s, ++i, 1)); c = ord(substr(s, ++i, 1));
            if (b >= 0x80 && b <= 0xbf && c >= 0x80 && c <= 0xbf &&
                !(a == 0xe0 && b < 0xa0) && !(a == 0xed && b >= 0xa0))
                code = ((a & 15) << 12) | ((b & 63) << 6) | (c & 63);
        }
        if (code == null || code < 0x20 || code == 0x7f || (code >= 0x80 && code < 0xa0)) return null;
        result += sprintf('%04X', code); chars++;
        if (chars > 70) return null;
    }
    return result;
}
function ucs2_decode(hex) {
    if (length(hex) % 4) return null;
    let result = '';
    for (let i = 0; i < length(hex); i += 4) {
        let code = int(substr(hex, i, 4), 16);
        if (code >= 0xd800 && code <= 0xdbff) {
            if (i + 8 > length(hex)) return null;
            let low = int(substr(hex, i + 4, 4), 16);
            if (low < 0xdc00 || low > 0xdfff) return null;
            code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00; i += 4;
        }
        else if (code >= 0xdc00 && code <= 0xdfff) return null;
        result += utf8(code);
    }
    return result;
}
const GSM = {
    '0':'@','1':'£','2':'$','3':'¥','4':'è','5':'é','6':'ù','7':'ì','8':'ò','9':'Ç','10':'\n','11':'Ø','12':'ø','13':'\r','14':'Å','15':'å',
    '16':'Δ','17':'_','18':'Φ','19':'Γ','20':'Λ','21':'Ω','22':'Π','23':'Ψ','24':'Σ','25':'Θ','26':'Ξ','28':'Æ','29':'æ','30':'ß','31':'É',
    '36':'¤','64':'¡','91':'Ä','92':'Ö','93':'Ñ','94':'Ü','95':'§','96':'¿','123':'ä','124':'ö','125':'ñ','126':'ü','127':'à'
};
const GSM_EXT = {'10':'\f','20':'^','40':'{','41':'}','47':'\\','60':'[','61':'~','62':']','64':'|','101':'€'};
function gsm7(hex, start_bit, count) {
    let result = '', escape = false;
    for (let i = 0; i < count; i++) {
        let bit = start_bit + i * 7, off = int(bit / 8), shift = bit % 8;
        let first = byte(hex, off), second = byte(hex, off + 1);
        if (first == null) return null;
        let v = ((first >> shift) | ((second || 0) << (8 - shift))) & 0x7f;
        if (escape) { result += GSM_EXT[v] || '?'; escape = false; }
        else if (v == 27) escape = true;
        else result += GSM[v] || chr(v);
    }
    return result;
}
function digits(hex, n) {
    let result = '';
    for (let i = 0; i < n; i++) {
        let b = byte(hex, int(i / 2));
        if (b == null) return null;
        let d = i % 2 ? (b >> 4) : (b & 15);
        result += d == 10 ? '*' : d == 11 ? '#' : d == 12 ? 'a' : d == 13 ? 'b' : d == 14 ? 'c' : d < 10 ? sprintf('%d', d) : '';
    }
    return result;
}
function timestamp(hex) {
    if (length(hex) < 14) return '';
    let d = [];
    for (let i = 0; i < 6; i++) {
        let b = byte(hex, i);
        if (b == null || (b & 15) > 9 || (b >> 4) > 9) return '';
        push(d, sprintf('%02d', (b & 15) * 10 + (b >> 4)));
    }
    return '20' + d[0] + '-' + d[1] + '-' + d[2] + ' ' + d[3] + ':' + d[4] + ':' + d[5];
}
function decode_pdu(pdu, include_text) {
    if (!pdu || length(pdu) < 4 || length(pdu) > 1024 || length(pdu) % 2 ||
        !match(pdu, /^[0-9A-Fa-f]+$/)) return null;
    let hex = uc(pdu), smsc = byte(hex, 0), pos = smsc + 1;
    let fo = byte(hex, pos++);
    if (fo == null) return null;
    let kind = fo & 3, address = '', sent_time = '';
    if (kind == 1) pos++; // SMS-SUBMIT message reference
    if (kind != 0 && kind != 1) return {from:'',time:'',text:null,unsupported:true};
    let n = byte(hex, pos++), toa = byte(hex, pos++);
    if (n == null || toa == null || n > 40) return null;
    let adr_len = (toa & 0x70) == 0x50 ? int((n * 7 + 7) / 8) : int((n + 1) / 2);
    let adr = substr(hex, pos * 2, adr_len * 2);
    if (length(adr) != adr_len * 2) return null;
    address = (toa & 0x70) == 0x50 ? gsm7(adr, 0, n) : digits(adr, n);
    if ((toa & 0x70) == 0x10 && address) address = '+' + address;
    pos += adr_len;
    pos++; // PID
    let dcs = byte(hex, pos++);
    if (dcs == null) return null;
    if (kind == 0) {
        sent_time = timestamp(substr(hex, pos * 2, 14)); pos += 7;
    }
    else {
        let vpf = (fo >> 3) & 3;
        if (vpf == 2) pos++; else if (vpf == 1 || vpf == 3) pos += 7;
    }
    let udl = byte(hex, pos++), ud = substr(hex, pos * 2);
    if (udl == null) return null;
    let data = {from:address || '',time:sent_time,text:null,unsupported:false,concat:null};
    let header = (fo & 0x40) ? (byte(ud, 0) || 0) + 1 : 0;
    if (header > 140 || (fo & 0x40 && (header < 2 || length(ud) < header * 2))) return null;
    // 3GPP TS 23.040: IEI 00 is an 8-bit concatenation reference; IEI 08
    // carries a 16-bit reference. Keep these fields even for a list request,
    // which deliberately does not disclose message text.
    for (let p = 1; p < header;) {
        let iei = byte(ud, p++), size = byte(ud, p++);
        if (iei == null || size == null || p + size > header) return null;
        let bits = iei == 0 && size == 3 ? 8 : iei == 8 && size == 4 ? 16 : 0;
        if (bits) {
            let ref = bits == 8 ? byte(ud, p) : (byte(ud, p) << 8) | byte(ud, p + 1);
            let total = byte(ud, p + (bits == 8 ? 1 : 2));
            let part = byte(ud, p + (bits == 8 ? 2 : 3));
            if (total < 2 || total > 20 || part < 1 || part > total || data.concat) return null;
            data.concat = {bits,ref,total,part};
        }
        p += size;
    }
    if (!include_text) return data;
    let coding = dcs & 12;
    if (coding == 8) {
        if (udl < header || length(ud) < udl * 2) return null;
        data.text = ucs2_decode(substr(ud, header * 2, (udl - header) * 2));
    }
    else if (coding == 0) {
        let skip = int((header * 8 + 6) / 7);
        if (udl < skip || length(ud) < int((udl * 7 + 7) / 8) * 2) return null;
        data.text = gsm7(ud, skip * 7, udl - skip);
    }
    else { data.unsupported = true; }
    return data;
}
function parse_storage(raw) {
    let m = match(raw || '', /\+CPMS:\s*"(ME|SM|MT)",([0-9]+),([0-9]+),"(ME|SM|MT)",([0-9]+),([0-9]+),"(ME|SM|MT)",([0-9]+),([0-9]+)/);
    if (!m) return error('PARSE', '无法读取短信存储状态');
    let used = +m[2], capacity = +m[3];
    return {ok:true,storage:m[1],used,capacity,total:capacity,full:capacity > 0 && used >= capacity,
        write_storage:m[4],receive_storage:m[7],receive_used:+m[8],receive_capacity:+m[9],timestamp:time()};
}
function parse_list(raw, storage) {
    let lines = split(raw || '', /\r?\n/), messages = [];
    for (let i = 0; i < length(lines) - 1; i++) {
        let m = match(lines[i], /^\+CMGL:\s*([0-9]+),([0-3]),/);
        if (!m) continue;
        let pdu = trim(lines[++i] || ''), decoded = decode_pdu(pdu, false);
        if (!decoded) return error('PARSE', '短信目录格式无法识别');
        push(messages, {index:+m[1],status:['未读','已读','待发','已发'][+m[2]],from:decoded.from,time:decoded.time,storage,unsupported:decoded.unsupported,concat:decoded.concat});
        if (length(messages) > 255) return error('PARSE', '短信目录数量异常');
    }
    let groups = [];
    for (let message in messages) {
        let c = message.concat, found = null;
        if (c) for (let group in groups) {
            // Reused references and sender collisions must not combine unrelated
            // texts. Day-boundary messages may stay separate rather than risk it.
            if (group.concat && group.from == message.from &&
                group.time_day == substr(message.time, 0, 10) &&
                group.concat.bits == c.bits && group.concat.ref == c.ref &&
                group.concat.total == c.total && !group.parts[c.part - 1]) { found = group; break; }
        }
        if (!found) {
            found = {index:message.index,status:message.status,from:message.from,time:message.time,
                time_day:substr(message.time,0,10),storage,concat:c,parts:c ? [] : [message.index]};
            push(groups, found);
        }
        if (c) found.parts[c.part - 1] = message.index;
        if (message.status == '未读') found.status = '未读';
    }
    for (let group in groups) {
        group.complete = !group.concat || length(filter(group.parts,p=>p != null)) == group.concat.total;
        delete group.time_day;
    }
    return {ok:true,storage,messages,groups,count:length(messages),conversation_count:length(groups)};
}
function parse_read(raw, index, storage) {
    let lines = split(raw || '', /\r?\n/);
    for (let i = 0; i < length(lines) - 1; i++) {
        let m = match(lines[i], /^\+CMGR:\s*([0-3]),/);
        if (!m) continue;
        let decoded = decode_pdu(trim(lines[i + 1] || ''), true);
        if (!decoded) return error('PARSE', '短信内容格式无法识别');
        return {ok:true,message:{index,status:['未读','已读','待发','已发'][+m[1]],from:decoded.from,time:decoded.time,
            text:decoded.text,storage,unsupported:decoded.unsupported,concat:decoded.concat}};
    }
    return error('PARSE', '未找到该短信');
}
function encode_submit(to, text) {
    if (type(to) != 'string' || !match(to, /^\+?[0-9]{3,15}$/)) return null;
    let data = ucs2_encode(text);
    if (data == null) return null;
    let digits_only = replace(to, /^\+/, ''), swapped = '';
    for (let i = 0; i < length(digits_only); i += 2) {
        swapped += substr(digits_only, i + 1, 1) || 'F';
        swapped += substr(digits_only, i, 1);
    }
    let tpdu = '0100' + sprintf('%02X', length(digits_only)) + (substr(to, 0, 1) == '+' ? '91' : '81') + swapped +
        '0008' + sprintf('%02X', length(data) / 2) + data;
    return {pdu:'00' + tpdu,length:length(tpdu) / 2};
}
function load_request(path) {
    if (!TEST && path != '/tmp/kk-car-dji-sms-request-lock/request.json') return null;
    let s = stat(path);
    if (!s || s.type != 'file' || s.uid != 0 || s.size > 1024 ||
        s.perm.group_read || s.perm.group_write || s.perm.other_read || s.perm.other_write) return null;
    try { let value = json(readfile(path) || ''); return type(value) == 'object' ? value : null; }
    catch (e) { return null; }
}
function call_status(raw) {
    let state='idle',direction=null,count=0,number=null;
    for (let line in split(raw || '',/\r?\n/)) {
        let call=match(line,/^\+CLCC:\s*[0-9]+,([01]),([0-5]),([0-2]),[01]/);
        if (!call) continue;
        // This QDC507 firmware reports two active mode=1 data sessions in
        // CLCC. Count only mode=0 voice calls, never data bearers as calls.
        if (call[3]!='0') continue;
        count++;
        let names=['通话中','保持中','正在拨号','对方振铃','来电振铃','来电等待'];
        if (state=='idle' || +call[2]>=4) {
            state=names[+call[2]];
            direction=call[1]=='1'?'incoming':'outgoing';
            let numbered=match(line,/^\+CLCC:[^\r\n]*?,"(\+?[0-9]{3,15})"/);
            number=numbered ? numbered[1] : null;
        }
    }
    return {ok:true,state,direction,count,number,timestamp:time()};
}
function voice_ready() {
    return system('/etc/kk-car/dji-voice-health.sh prepared >/dev/null 2>&1') == 0;
}
function perform(session, action, param) {
    if (action == 'storage_probe') {
        let response=at(session,'AT+CPMS=?',5);
        if (!response.ok) return response;
        let m=match(response.data,/\+CPMS:\s*\(([^)]*)\),\s*\(([^)]*)\),\s*\(([^)]*)\)/);
        let cnmi=at(session,'AT+CNMI?',5);
        let route=cnmi.ok ? match(cnmi.data,/\+CNMI:\s*[0-9]+,([0-3]),/) : null;
        return m ? {ok:true,sim_read:!!match(m[1],/"SM"/),
            sim_write:!!match(m[2],/"SM"/),sim_receive:!!match(m[3],/"SM"/),
            incoming_mode:route ? +route[1] : null} :
            error('PARSE','模块未返回短信存储能力');
    }
    if (action == 'voice_probe') {
        // Read-only capability check. Never dial, answer, hang up, or change
        // the persistent USB/IMS configuration from this endpoint.
        let usb=at(session,'AT+QCFG="usbcfg"',5);
        let ims=at(session,'AT+QCFG="ims"',5);
        let calls=at(session,'AT+CLCC',5);
        let voice=usb.ok ? match(usb.data,/\+QCFG:\s*"usbcfg",[^\r\n]*,([01])\r?\n/) : null;
        let ims_value=ims.ok ? match(ims.data,/\+QCFG:\s*"ims",([0-2])/) : null;
        let audio=false;
        for (let entry in glob('/sys/bus/usb/devices/*:*')) {
            let parent=replace(entry,/:[0-9]+\.[0-9]+$/,'');
            if (trim(readfile(parent+'/idVendor') || '')=='2c7c' &&
                trim(readfile(parent+'/idProduct') || '')=='0125' &&
                trim(readfile(entry+'/bInterfaceClass') || '')=='01') audio=true;
        }
        // CLCC exposes phone numbers; return only the call direction and state.
        let current=call_status(calls.ok ? calls.data : '');
        return {ok:true,usb_voice_enabled:voice ? voice[1]=='1' : null,
            ims_setting:ims_value ? +ims_value[1] : null,
            call_query_accepted:calls.ok,audio_usb_present:audio,
            call_state:current.state,call_direction:current.direction,active_calls:current.count,
            ready:voice_ready() && audio && ims_value && ims_value[1]=='1',
            route_ready:system('/etc/kk-car/dji-voice-health.sh active >/dev/null 2>&1') == 0,
            reason:'USB 声卡和模块驱动已准备；接通后启动音频路由，双方语音仍需实测'};
    }
    if (action == 'call_status') {
        let calls=at(session,'AT+CLCC',5);
        if (!calls.ok) return error('CALL_STATUS','通话状态暂不可读');
        let current=call_status(calls.data);
        let active=stat('/tmp/kk-car-voice-ready')?.type=='file';
        if (!current.count) {
            if (active) system('/etc/kk-car/dji-voice-route.sh stop >/dev/null 2>&1');
            unlink('/tmp/kk-car-voice-outgoing-pending');
        }
        else if (current.state=='通话中' && current.direction=='outgoing' &&
                 stat('/tmp/kk-car-voice-outgoing-pending')?.type=='file' && !active) {
            if (system('/etc/kk-car/dji-voice-route.sh start >/dev/null 2>&1')==0)
                unlink('/tmp/kk-car-voice-outgoing-pending');
        }
        current.audio_ready=stat('/tmp/kk-car-voice-ready')?.type=='file';
        return current;
    }
    if (action == 'call_diag') {
        // Read only. Never expose caller IDs, IMSI, or raw modem output.
        let cause=at(session,'AT+CEER',5);
        let reg=at(session,'AT+CIREG?',5);
        let ims=at(session,'AT+QCFG="ims"',5);
        let volte=at(session,'AT+QCFG="volte_disable"',5);
        let contexts=at(session,'AT+CGDCONT?',5);
        let active=at(session,'AT+CGACT?',5);
        let mbn=at(session,'AT+QMBNCFG="List"',5);
        let c=cause.ok ? match(cause.data,/\+CEER:\s*([0-9]+),\s*(-?[0-9]+)/) : null;
        let r=reg.ok ? match(reg.data,/\+CIREG:\s*([0-9]+),\s*([0-9]+)(?:,\s*([0-9]+))?/) : null;
        let i=ims.ok ? match(ims.data,/\+QCFG:\s*"ims",([0-2]),([01])/) : null;
        let v=volte.ok ? match(replace(volte.data,/volte\/disable/,'volte_disable'),
            /\+QCFG[:=]\s*"volte_disable",([01])/) : null;
        let pdn=contexts.ok ? match(contexts.data,/\+CGDCONT:\s*([0-9]+),"[^"]+","[Ii][Mm][Ss]"/) : null;
        let pdn_active=null;
        if (pdn && active.ok) for (let line in split(active.data,/\r?\n/)) {
            let item=match(line,/^\+CGACT:\s*([0-9]+),([01])/);
            if (item && +item[1]==+pdn[1]) pdn_active=item[2]=='1';
        }
        let profile=null;
        if (mbn.ok) for (let line in split(mbn.data,/\r?\n/)) {
            let item=match(line,/^\+QMBNCFG:\s*"List",[0-9]+,[01],1,"([A-Za-z0-9_.-]{1,80})"/);
            if (item) profile=item[1];
        }
        return {ok:true,release_cause:c ? [+c[1],+c[2]] : null,
            ims_registration:r ? [+r[1],+r[2],r[3]==null?null:+r[3]] : null,
            ims_setting:i ? +i[1] : null,volte_capable:i ? i[2]=='1' : null,
            volte_disabled:v ? v[1]=='1' : null,ims_pdn_cid:pdn ? +pdn[1] : null,
            ims_pdn_active:pdn_active,
            mbn_profile:profile};
    }
    if (action == 'call_dial' || action == 'call_answer' || action == 'call_hangup') {
        if (!voice_ready()) return error('AUDIO_NOT_READY','模块双向音频路由尚未就绪');
        let current=at(session,'AT+CLCC',5);
        if (!current.ok) return error('CALL_STATUS','无法确认当前电话状态');
        let status=call_status(current.data);
        if (action == 'call_dial') {
            if (!match(param,/^\+?[0-9]{3,15}$/)) return error('NUMBER','电话号码格式不正确');
            if (status.count) return error('CALL_BUSY','已有通话，不能重复拨号');
            let result=at(session,'ATD'+param+';',12);
            if (!result.ok) return error('DIAL_FAILED','模块未接受拨号');
            writefile('/tmp/kk-car-voice-outgoing-pending','1');
            return {ok:true,accepted:true};
        }
        if (action == 'call_answer') {
            if (status.direction!='incoming' || status.count<1) return error('NO_INCOMING','当前没有待接来电');
            let result=at(session,'ATA',12);
            if (!result.ok) return error('ANSWER_FAILED','模块未接受接听');
            let connected=false;
            for (let n=0; n<30; n++) {
                let latest=at(session,'AT+CLCC',3);
                if (latest.ok && call_status(latest.data).state=='通话中') { connected=true; break; }
                sleep(0.1);
            }
            if (!connected) return error('ANSWER_FAILED','模块未确认通话接通');
            // The notifier may sample ringing and idle without seeing the
            // short active interval. Keep a number-free answer marker until
            // it classifies the end of this call.
            writefile('/tmp/kk-car-voice-answered','' + time());
            chmod('/tmp/kk-car-voice-answered',0600);
            if (system('/etc/kk-car/dji-voice-route.sh start >/dev/null 2>&1')!=0) {
                at(session,'ATH',5);
                return error('AUDIO_FAILED','已接通，但模块音频路由启动失败，已尝试挂断');
            }
            return {ok:true,accepted:true};
        }
        if (!status.count) {
            if (stat('/tmp/kk-car-voice-ready')?.type=='file')
                system('/etc/kk-car/dji-voice-route.sh stop >/dev/null 2>&1');
            return {ok:true,accepted:false};
        }
        let result=at(session,'ATH',12);
        if (result.ok) {
            unlink('/tmp/kk-car-voice-outgoing-pending');
            system('/etc/kk-car/dji-voice-route.sh stop >/dev/null 2>&1');
        }
        return result.ok ? {ok:true,accepted:true} : error('HANGUP_FAILED','模块未接受挂断');
    }
    if (action == 'gps_probe' || action == 'gps_start' || action == 'gps_stop') {
        let state=at(session,'AT+QGPS?',5);
        let mode=state.ok ? match(state.data,/\+QGPS:\s*([01])\r?\n/) : null;
        if (!mode) return error('GPS_UNSUPPORTED','模块未返回定位状态');
        let enabled=mode[1]=='1';
        if (action == 'gps_start' && !enabled) {
            let started=at(session,'AT+QGPS=1',8);
            if (!started.ok) return error('GPS_START','模块未能启动定位');
            enabled=true;
        }
        if (action == 'gps_stop' && enabled) {
            let stopped=at(session,'AT+QGPSEND',8);
            if (!stopped.ok) return error('GPS_STOP','模块未能停止定位');
            enabled=false;
        }
        let result={ok:true,supported:true,enabled,fix:false,lat:null,lon:null,
            speed_kmh:null,hdop:null,satellites:null,updated_at:time()};
        if (!enabled) return result;
        let position=at(session,'AT+QGPSLOC=2',5);
        if (!position.ok) return result;
        let line=match(position.data,/\+QGPSLOC:\s*([^\r\n]+)/);
        if (!line) return result;
        let fields=split(line[1],',');
        if (length(fields)!=11) return result;
        let lat=+fields[1],lon=+fields[2],hdop=+fields[3],fix=+fields[5],
            speed=+fields[7],satellites=+fields[10];
        if (!match(fields[1],/^-?[0-9]+\.[0-9]+$/) ||
            !match(fields[2],/^-?[0-9]+\.[0-9]+$/) ||
            !match(fields[3],/^[0-9]+(\.[0-9]+)?$/) ||
            !match(fields[7],/^[0-9]+(\.[0-9]+)?$/) ||
            !match(fields[10],/^[0-9]+$/) ||
            lat < -90 || lat > 90 || lon < -180 || lon > 180 ||
            hdop < 0 || hdop > 100 || speed < 0 || speed > 2000 ||
            satellites < 0 || satellites > 99 || (fix!=2 && fix!=3)) return result;
        result.fix=true;result.lat=lat;result.lon=lon;result.hdop=hdop;
        result.speed_kmh=speed;result.satellites=satellites;
        return result;
    }
    let format = at(session, 'AT+CMGF?', 5);
    if (!format.ok) return format;
    if (!match(format.data, /\+CMGF:\s*0\r?\n/)) return error('MODE', '模块当前不在 PDU 短信模式');
    if (action == 'storage_select_sim' || action == 'storage_select_me') {
        let target = action == 'storage_select_sim' ? 'SM' : 'ME';
        let changed = at(session, 'AT+CPMS="' + target + '","' + target + '","' + target + '"', 8);
        if (!changed.ok) return changed;
        let selected = at(session, 'AT+CPMS?', 5);
        if (!selected.ok) return selected;
        let state = parse_storage(selected.data);
        return state.ok && state.storage == target && state.write_storage == target &&
            state.receive_storage == target && state.capacity > 0 ? state :
            error('STORAGE', '短信存储未切换到指定位置');
    }
    let storage = at(session, 'AT+CPMS?', 5);
    if (!storage.ok) return storage;
    let state = parse_storage(storage.data);
    if (!state.ok) return state;
    if (state.storage != 'SM' || state.write_storage != 'SM' || state.receive_storage != 'SM') {
        let changed = at(session, 'AT+CPMS="SM","SM","SM"', 8);
        if (!changed.ok) return error('STORAGE', 'SIM 短信仓无法启用');
        let selected = at(session, 'AT+CPMS?', 5);
        if (!selected.ok) return selected;
        state = parse_storage(selected.data);
        if (!state.ok || state.storage != 'SM' || state.write_storage != 'SM' ||
            state.receive_storage != 'SM' || state.capacity < 1)
            return error('STORAGE', 'SIM 短信仓未正确启用');
    }
    if (action == 'storage') return state;
    if (action == 'send') {
        let request = load_request(param), submit = request ? encode_submit(request.to, request.text) : null;
        if (!submit) return error('INPUT', '手机号或短信内容不符合要求');
        let prompt = exchange(session, 'AT+CMGS=' + submit.length + '\r', 6, true);
        if (!prompt.ok) return prompt;
        let sent = exchange(session, submit.pdu + chr(26), 120, false);
        if (!sent.ok) return sent.code == 'TIMEOUT' ? error('SEND_UNKNOWN', '发送结果未确认，请勿立即重试') : sent;
        let ref = match(sent.data, /\+CMGS:\s*([0-9]+)/);
        return ref ? {ok:true,reference:+ref[1]} : error('SEND_UNKNOWN', '模块未返回短信编号，请勿立即重试');
    }
    if (action == 'list') {
        let result = at(session, 'AT+CMGL=4', 10);
        return result.ok ? parse_list(result.data, state.storage) : result;
    }
    if (!match(param || '', /^(0|[1-9][0-9]{0,2})$/) || +param > 255)
        return error('INPUT', '短信编号无效');
    if (action == 'read') {
        let result = at(session, 'AT+CMGR=' + param, 6);
        return result.ok ? parse_read(result.data, +param, state.storage) : result;
    }
    if (action == 'delete') {
        let result = at(session, 'AT+CMGD=' + param + ',0', 6);
        return result.ok ? {ok:true,index:+param} : result;
    }
    return error('INPUT', '不支持的短信操作');
}

let action = ARGV[0] || '', param = ARGV[1] || '', result = null;
if (!match(action, /^(storage|storage_probe|storage_select_sim|storage_select_me|list|read|send|delete|voice_probe|call_status|call_diag|call_dial|call_answer|call_hangup|gps_probe|gps_start|gps_stop)$/)) result = error('INPUT', '不支持的模块操作');
else if (getenv('KK_CAR_DJI_SMS_LOCKED') != '1') {
    // The read-only AT probes use flock on this same file. Re-exec under that
    // lock so the lock is held for the full serial session and cleaned by the
    // kernel even if this process is killed.
    let script = TEST ? (getenv('KK_CAR_SMS_TEST_SCRIPT') || '') : '/etc/kk-car/dji-sms.uc';
    let safe_script = TEST ? match(script, /^\/tmp\/[A-Za-z0-9_./-]+\.uc$/) : true;
    let safe_param = action == 'send' ?
        (TEST ? match(param, /^\/tmp\/[A-Za-z0-9_./-]+$/) : param == '/tmp/kk-car-dji-sms-request-lock/request.json') :
        (action == 'read' || action == 'delete' ? match(param, /^(0|[1-9][0-9]{0,2})$/) :
         action == 'call_dial' ? match(param,/^\+?[0-9]{3,15}$/) : param == '');
    if (!safe_script || !safe_param) result = error('INPUT', '操作参数无效');
    else {
        let p = popen('KK_CAR_DJI_SMS_LOCKED=1 flock -n ' + LOCK + ' ucode ' + script +
            ' ' + action + (param ? ' ' + param : '') + ' 2>/dev/null');
        let output = p ? trim(p.read('all') || '') : '';
        if (p) p.close();
        if (output) { print(output + '\n'); exit(0); }
        result = error('BUSY', '模块正在执行其他操作，请稍后再试');
    }
}
else {
    let tty = device();
    if (!tty) result = error('DEVICE', '未找到 DJI 模块短信接口');
    else {
        let session = session_start(tty);
        if (!session.ok) result = session;
        else {
            try { result = perform(session, action, param); }
            catch (e) { result = error('INTERNAL', '短信操作失败'); }
            session.writer.close(); clean();
        }
    }
}
print(sprintf('%J\n', result || error('INTERNAL', '短信操作失败')));
