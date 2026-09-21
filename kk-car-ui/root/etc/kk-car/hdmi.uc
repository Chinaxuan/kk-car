'use strict';
// Read-only local display. Never modifies networking or invokes network probes.
import { readfile, writefile, open, rename } from 'fs';
import { connect } from 'ubus';
const C={bg:0x101720,panel:0x18232f,line:0x304150,white:0xe8eff6,muted:0x9aabba,
 blue:0x89bfff,green:0x77ddba,purple:0xbaacff,cyan:0x6edbdc,amber:0xf2c477,red:0xff909b};
function fail(s){die('KK-Car HDMI: '+s+'\n');}
function numfile(p){return +(trim(readfile(p)||'0'));}
function repeat(s,n){let out='';while(n-->0)out+=s;return out;}
function pixel(c){return chr(c&255,(c>>8)&255,(c>>16)&255,255);}
function fresh(t,now,limit){return t!=null && t<=now && now-t<=limit;}
function memoryPercent(m){let t=m?.total,a=m?.available??m?.free;return t>0 && a!=null && a>=0?max(0.0,min(100.0,100.0*(t-a)/t)):null;}
function fmt(v,places,unit){return v==null?'未知':sprintf('%.'+places+'f',v)+(unit||'');}
function duration(v){if(v==null)return '未知';return sprintf('%d小时%02d分',int(v/3600),int(v%3600/60));}
function bytes(v){if(v==null)return '未知';return v>=1e9?sprintf('%.2f GB',v/1e9):sprintf('%.1f MB',v/1e6);}
function pair(a,b){return bytes(a)+' / '+bytes(b);}
function chars(s){let a=[];s=''+s;for(let i=0;i<length(s);){let b=ord(s,i),n=b<128?1:b<224?2:b<240?3:4;push(a,substr(s,i,n));i+=n;}return a;}
let args=ARGV||[],simulate=index(args,'--simulate')>=0,once=index(args,'--once')>=0;
let maxFrames=once?1:0;for(let arg in args){let m=match(arg,/^--frames=(\d+)$/);if(m){if(!simulate||+m[1]<1||+m[1]>120)fail('frame limit requires simulation, 1..120');maxFrames=+m[1];}}
let preview=index(args,'--preview-1080')>=0;if(preview&&!simulate)fail('preview geometry is simulation-only');
let geometry=split(trim(readfile('/sys/class/graphics/fb0/virtual_size')||''),',');
let width=+geometry[0],height=+geometry[1],stride=numfile('/sys/class/graphics/fb0/stride');
if(trim(readfile('/sys/class/graphics/fb0/name')||'')!='BCM2708 FB' || numfile('/sys/class/graphics/fb0/bits_per_pixel')!=32)fail('requires legacy 32-bit framebuffer');
if(trim(readfile('/sys/class/graphics/fb0/pan')||'0,0')!='0,0')fail('nonzero framebuffer offset');
if(!match(readfile('/proc/cmdline')||'',/bcm2708_fb\.fbswap=1/))fail('unverified pixel order');
if(preview){width=1920;height=1080;stride=7680;}
if(width<1280||height<720||width>1920||height>1080||stride<width*4||stride>32768)fail('supported output is 720p or 1080p');
let factor=width/1920.0;
let font=json(readfile('/etc/kk-car/hdmi-font.json')||'null');if(!font?.glyphs)fail('local font subset unavailable');
let canvas=[],glyphCache={},colors={},rectCache={},rectCount=0,frames=0;
function rect(x,y,w,h,c){x=int(x*factor);y=int(y*factor);w=int(w*factor);h=int(h*factor);if(w<1||h<1||x<0||y<0||x+w>width||y+h>height)return;
 let key=c+':'+w,data=rectCache[key]||repeat(pixel(c),w);if(!rectCache[key]&&rectCount<250){rectCache[key]=data;rectCount++;}
 for(let r=y;r<y+h;r++)canvas[r]=substr(canvas[r],0,x*4)+data+substr(canvas[r],(x+w)*4);}
function palette(fg,bg){let key=fg+':'+bg;if(colors[key])return colors[key];let out=[];
 for(let a=0;a<16;a++){let c=0;for(let shift in [0,8,16])c|=int((((fg>>shift)&255)*a+((bg>>shift)&255)*(15-a))/15)<<shift;push(out,pixel(c));}colors[key]=out;return out;}
function glyph(ch,size,fg,bg){let key=ch+':'+size+':'+fg+':'+bg;if(glyphCache[key])return glyphCache[key];
 let g=font.glyphs[''+size]?.[ch]||font.glyphs[''+size]['?'];let pal=palette(fg,bg),w=max(1,int(g.w*factor)),h=max(1,int(size*factor)),rows=[];
 for(let y=0;y<h;y++){let row='',src=g.rows[min(size-1,int(y/factor))];for(let x=0;x<w;x++)row+=pal[int(substr(src,min(g.w-1,int(x/factor)),1),16)];push(rows,row);}
 let out={w,h,advance:g.w,rows};glyphCache[key]=out;return out;}
function text(x,y,value,color,size,bg,limit){
 size||=22;bg??=C.panel;limit??=1800;let xx=int(x*factor),yy=int(y*factor),used=0,total=0,items=[];
 for(let ch in chars(value??'未知')){let g=glyph(ch,size,color,bg);if(used+g.advance>limit)break;push(items,g);total+=g.w;used+=g.advance;}
 if(!length(items)||xx<0||xx+total>width||yy<0||yy+items[0].h>height)return;
 // Compose short text rows first: one framebuffer-row replacement per label,
 // rather than copying the full screen row for every individual character.
 for(let r=0;r<items[0].h;r++){let parts=[];for(let g in items)push(parts,g.rows[r]);canvas[yy+r]=substr(canvas[yy+r],0,xx*4)+join('',parts)+substr(canvas[yy+r],(xx+total)*4);}
}
function panel(x,y,w,h,title,note){rect(x,y,w,h,C.panel);text(x+22,y+16,title,C.white,24);if(note)text(x+w-300,y+22,note,C.muted,18,C.panel,278);}
function absval(v){return v<0?-v:v;}
function line(x0,y0,x1,y1,c){
 let dx=x1-x0,dy=y1-y0;if(dx<0)return;
 if(absval(dy)<1){rect(x0,y0,max(2,dx+1),2,c);return;}
 let steps=max(1,int(dx));for(let i=0;i<=steps;i++){
  let a=y0+dy*i/steps,b=y0+dy*min(steps,i+1)/steps;
  rect(x0+i,min(a,b),2,max(2,absval(b-a)+1),c);
 }
}
function series(points,key,x,y,w,h,lo,hi,color){let old=null;for(let i=0;i<length(points);i++){let v=points[i][key];if(v==null){old=null;continue;}let p={x:x+w*i/119.0,y:y+h-h*max(0,min(1,(v-lo)/(hi-lo+0.0)))};if(old)line(old.x,old.y,p.x,p.y,color);old=p;}}
function details(x,title,rows,color){panel(x,530,446,330,title);for(let i=0;i<length(rows);i++){let y=584+i*32;text(x+22,y,rows[i][0],C.muted,20,C.panel,170);text(x+188,y,rows[i][1],rows[i][2]||color,20,C.panel,240);if(i<length(rows)-1)rect(x+22,y+27,402,1,C.line);}}
function atomic(s){let p=simulate?'/tmp/kk-car-hdmi-test-status.json':'/tmp/kk-car-hdmi-status.json';writefile(p+'.new',sprintf('%J\n',s));rename(p+'.new',p);}
let bus=connect();if(!bus)fail('ubus unavailable');
let fb=open(simulate?'/tmp/kk-car-hdmi-test.raw':'/dev/fb0',simulate?'w+':'r+');if(!fb)fail('output unavailable');
let previous=null,points=[];let blank=repeat(pixel(C.bg),width)+repeat(chr(0),stride-width*4);
while(true){let started=+(split(readfile('/proc/uptime')||'0',' ')[0]);let s=bus.call('kkcar','status'),now=time();if(!s?.telemetry)fail('status RPC unavailable');
 let cpu=null,down=null,up=null;if(previous&&s.uptime>previous.uptime){let t=s.telemetry.cpu.total-previous.telemetry.cpu.total,i=s.telemetry.cpu.idle-previous.telemetry.cpu.idle,dt=s.uptime-previous.uptime;if(t>0&&i>=0&&i<=t)cpu=100.0*(t-i)/t;
 if(s.uplink?.active==previous.uplink?.active&&s.wan.rx>=previous.wan.rx&&s.wan.tx>=previous.wan.tx){down=8.0*(s.wan.rx-previous.wan.rx)/dt/1e6;up=8.0*(s.wan.tx-previous.wan.tx)/dt/1e6;}}
 let ping=s.vpn_ping||{},m=s.modem||{},pingFresh=fresh(ping.uptime,s.uptime,25),modemFresh=fresh(m.timestamp,now,75)&&m.online;
 let latency=s.vpn.connected&&pingFresh&&ping.state=='ok'?ping.avg_ms:null;
 let signal=modemFresh&&m.connected&&match(m.network||'',/LTE|4G/)?m.rsrp:null;if(signal!=null&&(signal>0||signal< -160))signal=null;
 let loss=pingFresh?ping.loss_percent:null,mem=memoryPercent(s.memory),wan=s.telemetry.wan,vpn=s.telemetry.vpn;
 push(points,{down,up,latency,signal});if(length(points)>120)shift(points);
 canvas=[];for(let y=0;y<height;y++)push(canvas,blank);
 text(32,22,'KK-CAR',C.white,40,C.bg);text(235,34,'车载网络 / 实时状态',C.muted,24,C.bg);
 let clock=localtime();text(1550,31,sprintf('%02d:%02d:%02d',clock.hour,clock.min,clock.sec),C.white,40,C.bg);rect(1868,40,12,12,frames%2?C.green:C.blue);
 let path='当前出口  '+(s.uplink?.active=='ethernet'?'有线 WAN':s.wan.up?'4G 蜂窝':'无可用出口')+'   /   VPN '+(s.vpn.connected?'已连接':'未连接')+'   /   热点 '+(s.wifi.enabled?'开启':'关闭')+'  '+s.wifi.band+'  '+s.wifi.channel+'信道  '+s.wifi.width+'MHz';
 text(32,88,path,C.muted,22,C.bg,1370);text(1510,88,'已运行 '+duration(s.uptime),C.muted,20,C.bg,380);
 rect(32,124,1856,1,C.line);
 let labels=['实时下载','实时上传','VPN 延迟','本轮丢包','LTE RSRP','CPU 占用'];
 let values=[fmt(down,2,''),fmt(up,2,''),fmt(latency,1,''),fmt(loss,0,''),fmt(signal,0,''),fmt(cpu,1,'')];
 let units=['Mbps','Mbps','ms','%','dBm','%'],accents=[C.blue,C.green,C.purple,loss>0?C.amber:C.green,C.cyan,C.blue];
 for(let i=0;i<6;i++){let x=32+i*312;text(x,146,labels[i],C.muted,22,C.bg);text(x,178,values[i],accents[i],40,C.bg,235);text(x+230,197,units[i],C.muted,20,C.bg,65);if(i<5)rect(x+294,146,1,74,C.line);}
 panel(32,250,916,256,'上下行流量','本次显示启动后 / Mbps');panel(972,250,916,256,'VPN 延迟与蜂窝信号','紫色 ms / 青色 dBm');
 let rateMax=1,latMax=100;for(let p in points){rateMax=max(rateMax,p.down||0,p.up||0);latMax=max(latMax,p.latency||0);}
 for(let j=0;j<=3;j++){let y=316+j*48;rect(104,y,820,1,C.line);rect(1044,y,760,1,C.line);text(50,y-9,sprintf('%.1f',rateMax*(3-j)/3.0),C.muted,18,C.panel,52);text(990,y-9,sprintf('%.0f',latMax*(3-j)/3.0),C.muted,18,C.panel,50);text(1823,y-9,''+(-30-j*40),C.cyan,18,C.panel,55);}
 series(points,'down',104,316,820,144,0,rateMax,C.blue);series(points,'up',104,316,820,144,0,rateMax,C.green);
 series(points,'latency',1044,316,760,144,0,latMax,C.purple);series(points,'signal',1044,316,760,144,-150,-30,C.cyan);
 text(54,475,'下载  /  上传',C.blue,18);text(655,475,'最多 10 分钟 · 每 5 秒更新',C.muted,18,C.panel,270);
 text(994,475,'最近探测 '+(pingFresh?fmt(ping.min_ms,1,'')+' / '+fmt(ping.max_ms,1,' ms'):'数据过期'),C.muted,18,C.panel,530);
 text(1590,475,'信号越接近 0 越强',C.muted,18,C.panel,278);
 let power=!s.power.known?'未知':s.power.undervoltage?'当前欠压':s.power.throttled?'当前降频':s.power.historical?'当前正常 / 曾欠压':'当前正常';
 details(32,'系统 / CPU',[
 ['CPU / 实际频率',fmt(cpu,1,'%')+' / '+fmt(s.telemetry.cpu.mhz,0,'MHz')],['负载 1 / 5 / 15',join(' / ',s.telemetry.loads)],
 ['可用 / 总内存',pair(s.memory.available,s.memory.total)],['内存使用',fmt(mem,1,'%')],['处理器温度',fmt(s.temperature,1,' C')],
 ['连接跟踪',s.telemetry.conntrack+' / '+s.telemetry.conntrack_max],['设备运行',duration(s.uptime)],['供电 / 降频',power,s.power.undervoltage?C.red:C.amber]],C.blue);
 details(502,'出口 / 接口',[
 ['出口设备',(s.wan.device||'未知')+' / '+(s.wan.up?'在线':'离线')],['接口地址',s.wan.ip||'未分配'],['接口在线',duration(s.wan.uptime)],['累计收 / 发',pair(s.wan.rx,s.wan.tx)],
 ['包数 收 / 发',(wan.rx_packets??'?')+' / '+(wan.tx_packets??'?')],['累计错 / 丢',((wan.rx_errors||0)+(wan.tx_errors||0))+' / '+((wan.rx_dropped||0)+(wan.tx_dropped||0))],
 ['MTU / 网口',wan.mtu+' / '+s.ethernet.mode],['IPv6 状态',s.ipv6_disabled?'已关闭':'需要检查',s.ipv6_disabled?C.green:C.amber]],C.blue);
 let cipher=replace(s.telemetry.cipher||'未知','AES_CBC-','AES-');cipher=replace(cipher,'HMAC_SHA2_256_128','SHA256');
 details(972,'VPN / IPsec',[
 ['连接 / 分流',(s.vpn.connected?'已连接':'未连接')+' / '+(s.vpn.route?'就绪':'检查')],['隧道地址',s.vpn.ip||'未分配'],['已连接时长',duration(s.vpn.age)],['本 SA 收 / 发',pair(s.vpn.rx,s.vpn.tx)],
 ['ESP 加密',cipher],['换钥剩余',duration(s.telemetry.rekey)],['MTU / 累计错误',vpn.mtu+' / '+((vpn.rx_errors||0)+(vpn.tx_errors||0))],['探测 / 丢包',fmt(latency,1,'ms')+' / '+fmt(loss,0,'%')]],C.purple);
 details(1442,'蜂窝 / F30A Pro',[
 ['运营商',modemFresh?(m.operator||'未知'):'数据过期'],['网络 / 信号格',modemFresh?(m.network+' / '+m.bars+'格'):'未知'],['LTE RSRP',fmt(signal,0,' dBm')],['RSSI',fmt(modemFresh?m.rssi:null,0,' dBm')],
 ['蜂窝连接',modemFresh?(m.connected?'已连接':'未连接'):'未知'],['连接时长',modemFresh?duration(m.connection_uptime):'未知'],['上网棒运行',modemFresh?duration(m.uptime):'未知'],['累计收 / 发',modemFresh?pair(m.rx,m.tx):'未知']],C.cyan);
 panel(32,884,916,142,'热点与设备',s.wifi.clients+' 台无线在线');
 text(54,936,'SSID '+s.wifi.ssid+'   /   '+s.wifi.band+' · '+s.wifi.width+'MHz',C.white,20,C.panel,850);
 let peers=[];for(let p in s.peers||[])if(p.wireless)push(peers,p.ip);text(54,974,length(peers)?join('   /   ',peers):'没有已确认在线的无线设备',C.muted,20,C.panel,850);
 panel(972,884,916,142,'上次网络检查','只读结果，不自动发起检测');
 let d=s.diagnostics||{},age=d.timestamp?now-d.timestamp:null;
 let names=['国内出口','VPN 出口','公司服务','DNS','ChatGPT','Gemini'],keys0=['domestic','foreign','company','dns','chatgpt','gemini'];
 for(let i=0;i<6;i++){let k=keys0[i],v=d[k],status=age==null?'未检测':i<4?(v?'通过':'未通过'):(v?.country||'未知');let color=age==null||age>300?C.muted:i<4?(v?C.green:C.amber):(v?.country=='CN'?C.red:v?.country?C.green:C.amber);if(age>300)status+=' / 旧结果';text(994+(i%3)*294,936+int(i/3)*38,names[i]+' '+status,color,18,C.panel,278);}
 text(32,1045,'本地 '+ '192.168.88.1'+'   /   VPN '+(s.vpn.ip||'未分配')+'   /   只读状态屏',C.muted,18,C.bg,1320);
 text(1510,1045,preview?'1080p 布局预览':width+' x '+height+' / 5 秒刷新',C.muted,18,C.bg,375);
 let data=join('',canvas);fb.seek(0);if(fb.write(data)!=length(data)||!fb.flush())fail('framebuffer write failed');frames++;
 let elapsed=+(split(readfile('/proc/uptime')||'0',' ')[0])-started;
 atomic({timestamp:now,uptime:s.uptime,frames,width,height,stride,format:'BGRA',render_seconds:elapsed,cpu_percent:cpu,memory_percent:mem,download_mbps:down,upload_mbps:up,vpn_connected:s.vpn.connected,latency_ms:latency,rsrp_dbm:signal,wifi_clients:s.wifi.clients,simulated:simulate,layout:'dense-1080-zh'});
 previous=s;if(maxFrames&&frames>=maxFrames)break;sleep(int(max(1000,5000-elapsed*1000)));
}
fb.close();
