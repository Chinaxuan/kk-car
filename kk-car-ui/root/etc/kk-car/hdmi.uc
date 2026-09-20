'use strict';
// A small read-only framebuffer dashboard. No network/configuration mutations.
import { readfile, writefile, open, rename, access } from 'fs';
import { connect } from 'ubus';

// Original 5x7 bitmap alphabet; no external font or graphics runtime required.
const FONT = {
 ' ':[0,0,0,0,0,0,0], '0':[14,17,19,21,25,17,14],
 '1':[4,12,4,4,4,4,14], '2':[14,17,1,2,4,8,31],
 '3':[30,1,1,14,1,1,30], '4':[2,6,10,18,31,2,2],
 '5':[31,16,16,30,1,1,30], '6':[6,8,16,30,17,17,14],
 '7':[31,1,2,4,8,8,8], '8':[14,17,17,14,17,17,14],
 '9':[14,17,17,15,1,2,12], 'A':[14,17,17,31,17,17,17],
 'B':[30,17,17,30,17,17,30], 'C':[14,17,16,16,16,17,14],
 'D':[30,17,17,17,17,17,30], 'E':[31,16,16,30,16,16,31],
 'F':[31,16,16,30,16,16,16], 'G':[14,17,16,23,17,17,15],
 'H':[17,17,17,31,17,17,17], 'I':[14,4,4,4,4,4,14],
 'J':[7,2,2,2,18,18,12], 'K':[17,18,20,24,20,18,17],
 'L':[16,16,16,16,16,16,31], 'M':[17,27,21,21,17,17,17],
 'N':[17,25,25,21,19,19,17], 'O':[14,17,17,17,17,17,14],
 'P':[30,17,17,30,16,16,16], 'Q':[14,17,17,17,21,18,13],
 'R':[30,17,17,30,20,18,17], 'S':[15,16,16,14,1,1,30],
 'T':[31,4,4,4,4,4,4], 'U':[17,17,17,17,17,17,14],
 'V':[17,17,17,17,17,10,4], 'W':[17,17,17,21,21,21,10],
 'X':[17,17,10,4,10,17,17], 'Y':[17,17,10,4,4,4,4],
 'Z':[31,1,2,4,8,16,31], '-':[0,0,0,31,0,0,0],
 '.':[0,0,0,0,0,12,12], ':':[0,12,12,0,12,12,0],
 '/':[1,2,2,4,8,8,16], '%':[17,2,4,8,17,0,0],
 '+':[0,4,4,31,4,4,0], '?':[14,17,1,2,4,0,4]
};
const C = {bg:0x0b121d, card:0x132030, line:0x26394b, white:0xe8f2fa,
    muted:0x8b9fb3, cyan:0x50dfcf, blue:0x79b9ff, amber:0xffc56b, red:0xff7886};
function numberfile(path) { return +(trim(readfile(path) || '0')); }
function pixel(color) { return chr(color & 255, (color >> 8) & 255, (color >> 16) & 255, 255); }
function repeat(s, n) { let out=''; while(n-->0)out+=s; return out; }
function fail(message) { die('KK-Car HDMI: '+message+'\n'); }

let args=ARGV || [], once=index(args,'--once')>=0;
let simulate=index(args,'--simulate')>=0;
let fbname=trim(readfile('/sys/class/graphics/fb0/name') || '');
let size=split(trim(readfile('/sys/class/graphics/fb0/virtual_size') || ''),',');
let width=+size[0], height=+size[1], stride=numberfile('/sys/class/graphics/fb0/stride');
if(fbname!='BCM2708 FB' || numberfile('/sys/class/graphics/fb0/bits_per_pixel')!=32)
    fail('requires the Raspberry Pi legacy 32-bit framebuffer');
if(width<640 || height<360 || width>4096 || height>2160 || stride<width*4 || stride>32768)
    fail('unsupported framebuffer geometry');
let pan=trim(readfile('/sys/class/graphics/fb0/pan') || '0,0');
if(pan!='0,0')fail('nonzero framebuffer panning is not supported');
// BCM2708 FB on this Pi uses B,G,R,A bytes (boot fbswap=1). Fail closed otherwise.
if(!match(readfile('/proc/cmdline') || '', /bcm2708_fb\.fbswap=1/))
    fail('unverified pixel order');
let scale=int(min(width/640,height/360));
let ox=int((width-640*scale)/2), oy=int((height-360*scale)/2);
let canvas=[], cached={};
function rect(x,y,w,h,color) {
    x=ox+int(x*scale); y=oy+int(y*scale);w=int(w*scale);h=int(h*scale);
    if(w<=0 || h<=0 || x<0 || y<0 || x+w>width || y+h>height)return;
    let key=color+':'+w;
    let data=cached[key] ||= repeat(pixel(color),w);
    for(let r=y;r<y+h;r++)canvas[r]=substr(canvas[r],0,x*4)+data+substr(canvas[r],(x+w)*4);
}
function text(x,y,value,color,zoom) {
    value=uc(''+value);
    for(let i=0;i<length(value);i++) {
        let bits=FONT[substr(value,i,1)] || FONT['?'];
        for(let row=0;row<7;row++)for(let col=0;col<5;col++)
            if(bits[row] & (1<<(4-col)))rect(x+(i*6+col)*zoom,y+row*zoom,zoom,zoom,color);
    }
}
function bar(x,y,w,pct,color) {
    rect(x,y,w,3,C.line);rect(x,y,int(w*max(0,min(100,pct))/100),3,color);
}
function card(x,y,w,h) {rect(x,y,w,h,C.card);}
function duration(seconds) {return sprintf('%02dH %02dM',int(seconds/3600),int(seconds%3600/60));}
function fresh(stamp,now,limit) {return type(stamp)=='double' || type(stamp)=='int' ? stamp<=now && now-stamp<=limit : false;}
function atomic(value) {
    let path='/tmp/kk-car-hdmi-status.json';
    writefile(path+'.new',sprintf('%J\n',value));rename(path+'.new',path);
}

let previous=null, samples=[], frames=0;
let bus=connect(); if(!bus)fail('ubus is unavailable');
let fb=open(simulate?'/tmp/kk-car-hdmi-test.raw':'/dev/fb0',simulate?'w+':'r+');
if(!fb)fail('cannot open output');
let blankrow=repeat(pixel(C.bg),width)+repeat(chr(0),stride-width*4);
while(true) {
    let started=+(split(readfile('/proc/uptime') || '0',' ')[0]);
    let s=bus.call('kkcar','status'), now=time();
    if(!s || !s.telemetry)fail('KK-Car status RPC is unavailable');
    let cpu=null, down=null, up=null;
    if(previous && s.uptime>previous.uptime) {
        let total=s.telemetry.cpu.total-previous.telemetry.cpu.total;
        let idle=s.telemetry.cpu.idle-previous.telemetry.cpu.idle;
        if(total>0 && idle>=0 && idle<=total)cpu=100.0*(total-idle)/total;
        let dt=s.uptime-previous.uptime;
        // Suppress reset counters and changing uplink identities.
        if(s.uplink?.active==previous.uplink?.active && s.wan.rx>=previous.wan.rx && s.wan.tx>=previous.wan.tx) {
            down=(s.wan.rx-previous.wan.rx)*8/dt/1e6;up=(s.wan.tx-previous.wan.tx)*8/dt/1e6;
        }
    }
    let ping=s.vpn_ping || {}, modem=s.modem || {};
    let latency=s.vpn.connected && fresh(ping.uptime,s.uptime,25) && ping.state=='ok' ? ping.avg_ms : null;
    if(latency!=null && (latency<0 || latency>60000))latency=null;
    let signal=fresh(modem.timestamp,now,75) && modem.online && modem.connected && match(modem.network || '', /LTE|4G/) ? modem.rsrp : null;
    if(signal!=null && (signal>0 || signal< -160))signal=null;
    let available=s.memory.available || s.memory.free || 0;
    let memory=100.0*(1.0-available/max(1.0,s.memory.total));
    push(samples,latency);if(length(samples)>54)shift(samples);
    canvas=[];for(let y=0;y<height;y++)push(canvas,blankrow);

    rect(0,0,640,2,C.cyan);
    text(16,16,'KK-CAR',C.white,3);
    text(148,19,'ONBOARD / LIVE',C.muted,1);
    let clock=localtime();text(522,18,sprintf('%02d:%02d:%02d',clock.hour,clock.min,clock.sec),C.white,2);
    rect(502,22,6,6,frames%2?C.cyan:C.blue);
    card(0,54,312,100);card(324,54,316,100);
    text(16,68,'VPN / IKEV2',C.muted,1);
    text(204,68,s.vpn.connected?'CONNECTED':'OFFLINE',s.vpn.connected?C.cyan:C.red,1);
    text(16,91,latency==null?'--':sprintf('%.1f',latency),C.cyan,5);
    text(203,113,'MS',C.muted,2);
    text(16,136,latency==null?'PROBE UNAVAILABLE':'LATEST VPN ROUND TRIP',C.muted,1);
    text(340,68,'CELLULAR / '+(modem.network || 'UNKNOWN'),C.muted,1);
    text(340,91,signal==null?'--':sprintf('%d',signal),C.blue,5);
    text(466,113,'DBM',C.muted,2);
    text(340,136,signal==null?'MODEM DATA UNAVAILABLE':'RSRP / '+(signal>=-90?'STRONG':signal>=-110?'FAIR':'WEAK'),C.muted,1);
    for(let i=0;i<5;i++)rect(567+i*11,125-(i+1)*7,7,(i+1)*7,signal!=null && i<(modem.bars || 0)?C.blue:C.line);

    let names=['CPU LOAD','TEMPERATURE','MEMORY USED','WI-FI CLIENTS'];
    let values=[cpu==null?'--':sprintf('%.1f',cpu),sprintf('%.1f',s.temperature),sprintf('%.0f',memory),''+s.wifi.clients];
    let units=['%','C','%','ONLINE'],colors=[C.white,C.amber,C.blue,C.cyan];
    for(let i=0;i<4;i++) {
        let x=i*162;card(x,164,154,76);text(x+12,176,names[i],C.muted,1);
        text(x+12,197,values[i],colors[i],3);text(x+109,209,units[i],C.muted,1);
        if(i<3)bar(x+12,229,130,i==0?(cpu || 0):i==1?s.temperature:memory,colors[i]);
    }
    card(0,250,312,76);card(324,250,316,76);
    text(16,262,'VPN LATENCY / RECENT 5 MIN',C.muted,1);
    rect(16,312,280,1,C.line);
    let peak=100;for(let value in samples)if(value!=null)peak=max(peak,value);
    for(let i=0;i<length(samples);i++)if(samples[i]!=null) {
        let bh=max(2,int(28*samples[i]/peak));rect(17+i*5,311-bh,3,bh,C.cyan);
    }
    text(340,262,'UPLINK / '+(s.uplink?.active=='ethernet'?'ETHERNET':s.wan.up?'4G':'OFFLINE'),C.muted,1);
    text(340,283,'DOWN',C.muted,1);text(405,279,down==null?'--':sprintf('%.2f',down),C.blue,2);text(573,287,'MBPS',C.muted,1);
    text(340,309,'UP',C.muted,1);text(405,305,up==null?'--':sprintf('%.2f',up),C.cyan,2);text(573,313,'MBPS',C.muted,1);
    text(8,344,'UP '+duration(s.uptime),C.muted,1);
    let power=!s.power.known?'POWER UNKNOWN':s.power.undervoltage?'LOW VOLTAGE NOW':'POWER OK NOW';
    text(175,344,power,s.power.undervoltage?C.red:C.muted,1);
    text(373,344,'IPV6 '+(s.ipv6_disabled?'OFF':'CHECK'),s.ipv6_disabled?C.muted:C.amber,1);
    text(509,344,'REFRESH 5 SEC',C.muted,1);

    let data=join('',canvas);fb.seek(0);
    if(fb.write(data)!=length(data) || !fb.flush())fail('framebuffer write failed');
    frames++;
    let elapsed=+(split(readfile('/proc/uptime') || '0',' ')[0])-started;
    atomic({timestamp:now,uptime:s.uptime,frames,width,height,stride,format:'BGRA',
        render_seconds:elapsed,cpu_percent:cpu,vpn_connected:s.vpn.connected,
        latency_ms:latency,rsrp_dbm:signal,temperature:s.temperature,
        wifi_clients:s.wifi.clients,simulated:simulate});
    previous=s;
    if(once)break;
    sleep(int(max(1000,5000-elapsed*1000)));
}
fb.close();
