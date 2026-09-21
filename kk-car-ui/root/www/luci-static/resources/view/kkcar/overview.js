'use strict';
'require view';
'require rpc';
'require poll';

var getHistory = rpc.declare({object:'kkcar', method:'history', params:['range'], expect:{}});
var getStatus = rpc.declare({object:'kkcar', method:'status', expect:{}});
var action = rpc.declare({object:'kkcar', method:'action', params:['action'], expect:{}});
var saveAuto = rpc.declare({object:'kkcar', method:'auto_connect', params:['enabled'], expect:{}});
var saveWifi = rpc.declare({object:'kkcar', method:'wifi_save', params:['ssid','password','band'], expect:{}});
var confirmWifi = rpc.declare({object:'kkcar', method:'wifi_confirm', expect:{}});
var savePort = rpc.declare({object:'kkcar', method:'port_save', params:['mode'], expect:{}});
var confirmPort = rpc.declare({object:'kkcar', method:'port_confirm', expect:{}});

function bytes(n) {
    n = +n || 0;
    var unit = ['B','KB','MB','GB','TB'], i=0;
    while(n>=1024 && i<4) { n/=1024; i++; }
    return n.toFixed(i ? 1 : 0)+' '+unit[i];
}
function duration(n) {
    n = Math.max(0, +n || 0);
    if(n>=86400) return Math.floor(n/86400)+' 天 '+Math.floor(n%86400/3600)+' 小时';
    if(n>=3600) return Math.floor(n/3600)+' 小时 '+Math.floor(n%3600/60)+' 分钟';
    return Math.floor(n/60)+' 分 '+Math.floor(n%60)+' 秒';
}
function stamp(n) { return n ? new Date(n*1000).toLocaleTimeString('zh-CN',{hour12:false}) : '尚未检查'; }
function button(label, cb, type) { return E('button',{type:'button','class':'kk-button '+(type || ''),click:cb},label); }
function field(label, value, id) { return E('div',{'class':'kk-data-row'},[E('span',{},label),E('strong',id?{id:id}:{},value)]); }
function section(title, desc, children) {
    return E('section',{'class':'kk-section'},[E('div',{'class':'kk-section-head'},[E('h2',{},title),desc?E('p',{},desc):''])].concat(children));
}
function svgNode(tag, attrs) {
    var el=document.createElementNS('http://www.w3.org/2000/svg',tag);
    Object.keys(attrs || {}).forEach(function(k){el.setAttribute(k,attrs[k]);}); return el;
}

return view.extend({
    handleSaveApply:null, handleSave:null, handleReset:null,
    load:function(){return getStatus();},
    render:function(data){
        var self=this;
        this.previous=null; this.requesting=false; this.historyRange='1h'; this.historyRequest=0; this.historyFetched=0;
        document.title='KK-Car · 车载网络';
        if(!document.getElementById('kk-style')) document.head.appendChild(E('link',{id:'kk-style',rel:'stylesheet',href:L.resource('view/kkcar/overview.css')}));
        this.root=E('div',{'class':'kk-app'});
        var refresh=button('刷新状态',function(){self.refresh();});
        var diag=button('检查网络',function(){self.perform('diagnose');},'primary');
        this.ssid=E('input',{id:'kk-ssid',type:'text',value:data.wifi.ssid || '',autocomplete:'off',required:true});
        this.password=E('input',{id:'kk-password',type:'password',placeholder:'留空即保留原密码',autocomplete:'new-password',maxlength:63});
        this.band=E('select',{id:'kk-band'},[E('option',{value:'5g'},'5 GHz · 速度优先'),E('option',{value:'2g'},'2.4 GHz · 兼容性优先')]);
        this.band.value=data.wifi.band || '2g';
        this.wifiAck=E('input',{id:'kk-wifi-ack',type:'checkbox'});
        this.portMode=E('select',{id:'kk-port-mode'},[E('option',{value:'lan'},'LAN · 连接电脑等设备'),E('option',{value:'wan'},'WAN · 有线优先，4G 备用')]);
        this.portMode.value=data.ethernet && data.ethernet.mode || 'lan';
        this.portAck=E('input',{id:'kk-port-ack',type:'checkbox'});
        this.auto=E('input',{id:'kk-auto',type:'checkbox',checked:!!data.vpn.auto});
        var vpnButton=button('重新连接 VPN',function(){self.perform(self.data.vpn.running?'vpn_restart':'vpn_start');}); vpnButton.id='kk-reconnect';
        var pauseButton=button('暂停 VPN',function(){self.confirmArea.hidden=!self.confirmArea.hidden;}); pauseButton.id='kk-pause';
        this.confirmArea=E('div',{'class':'kk-inline-confirm',hidden:true},[
            E('strong',{},'暂停后，国外网站和公司内网将暂时不可用。'),
            E('p',{},'国内仍按原方式直连。下次开机是否连接，由下方的自动连接设置决定。'),
            button('确认暂停',function(){self.confirmArea.hidden=true;self.perform('vpn_stop');},'danger'),
            button('取消',function(){self.confirmArea.hidden=true;})
        ]);
        var wanAck=E('input',{id:'kk-wan-ack',type:'checkbox'});
        var wanButton=button('重新连接上网棒',function(){
            if(!wanAck.checked){self.message('请先确认已了解重连会短暂中断网络。',true);return;}
            wanAck.checked=false;self.perform('wan_restart');
        });
        this.root.append(
            E('div',{'class':'kk-header',role:'banner'},[
                E('div',{'class':'kk-brand'},[E('span',{'class':'kk-monogram','aria-hidden':'true'},'KK'),E('div',{},[E('h1',{},'车载网络'),E('p',{},'KK-Car · 你的随行网络')])]),
                E('div',{'class':'kk-header-links'},[E('span',{id:'kk-refreshed'},'正在读取'),E('a',{href:L.url('admin/kkcar_notifications')},'飞书推送'),E('a',{href:L.url('admin/status/overview')},'高级管理 ↗'),E('a',{href:L.url('admin/logout')},'退出')])
            ]),
            E('div',{id:'kk-message','class':'kk-notice',role:'status','aria-live':'polite',hidden:true}),
            E('div',{id:'kk-pending','class':'kk-notice warning',hidden:true},[
                E('strong',{},'热点设置正在试用'),E('p',{id:'kk-pending-text'},''),
                button('已连上新热点，保留设置',function(){self.request(confirmWifi(),'已提交确认，正在保存新热点设置。');},'primary')
            ]),
            E('div',{id:'kk-port-pending','class':'kk-notice warning',hidden:true},[
                E('strong',{},'网口用途正在试用'),E('p',{id:'kk-port-pending-text'},''),
                button('管理连接正常，保留网口设置',function(){self.request(confirmPort(),'已提交确认，正在保存网口用途。');},'primary')
            ]),
            E('div',{id:'kk-power','class':'kk-power',hidden:true},[E('strong',{},'注意供电'),E('span',{id:'kk-power-text'},'')]),
            E('section',{'class':'kk-overview'},[
                E('div',{'class':'kk-overview-top'},[
                    E('div',{},[E('div',{'class':'kk-eyebrow'},'当前连接'),E('h2',{id:'kk-summary'},'读取网络状态…'),E('p',{id:'kk-summary-desc'},'')]),
                    E('div',{'class':'kk-actions'},[refresh,diag])
                ]),
                E('div',{'class':'kk-path'},[
                    E('div',{'class':'kk-path-node'},[E('span',{'class':'kk-node-label'},'01  上网出口'),E('strong',{id:'kk-wan-status'},'—'),E('span',{id:'kk-wan-detail'},'')]),
                    E('span',{'class':'kk-path-arrow','aria-hidden':'true'},'→'),
                    E('div',{'class':'kk-path-node'},[E('span',{'class':'kk-node-label'},'02  公司 VPN'),E('strong',{id:'kk-vpn-status'},'—'),E('span',{id:'kk-vpn-detail'},'')]),
                    E('span',{'class':'kk-path-arrow','aria-hidden':'true'},'→'),
                    E('div',{'class':'kk-path-node'},[E('span',{'class':'kk-node-label'},'03  热点'),E('strong',{id:'kk-wifi-name'},'—'),E('span',{id:'kk-wifi-detail'},'')])
                ]),
                E('div',{'class':'kk-routing'},[E('span',{},'当前分流'),E('strong',{},'国内直连'),E('span',{},'·'),E('strong',{},'国外 / 公司内网走 VPN'),E('span',{'class':'kk-muted'},'VPN 断开时，国外流量暂停')])
            ]),
            E('div',{'class':'kk-columns'},[
                E('div',{'class':'kk-main'},[
                    section('网络历史','下载、上传与 VPN 延迟共用时间范围；关闭页面后继续记录。',[
                        E('div',{'class':'kk-traffic-numbers'},[
                            E('div',{},[E('span',{},'↓ 下载'),E('strong',{id:'kk-rx-speed'},'—'),E('small',{},'Mbps')]),
                            E('div',{},[E('span',{},'↑ 上传'),E('strong',{id:'kk-tx-speed'},'—'),E('small',{},'Mbps')]),
                            E('div',{'class':'kk-traffic-total'},[E('span',{},'接口累计收 / 发'),E('b',{id:'kk-total'},'—')])
                        ]),
                        E('div',{'class':'kk-history-ranges',role:'group','aria-label':'历史时间范围'},[
                            ['1h','最近 1 小时'],['1d','最近 1 天'],['30d','最近 30 天']
                        ].map(function(item){return E('button',{type:'button','class':'kk-button quiet','data-range':item[0],'aria-pressed':item[0]==='1h'?'true':'false',click:function(){self.historyRange=item[0];self.loadHistory(true);}},item[1]);})),
                        E('div',{'class':'kk-chart-heading'},[E('strong',{},'上网速度'),E('span',{},'↓ 下载 / ↑ 上传 · Mbps')]),
                        E('div',{id:'kk-chart','class':'kk-chart kk-history-chart',role:'img','aria-label':'下载和上传历史'}),
                        E('div',{'class':'kk-chart-heading'},[E('strong',{},[E('span',{'class':'kk-legend-latency'},'VPN 延迟'),E('span',{'class':'kk-legend-signal'},'RSRP 信号')]),E('span',{},'左 ms · 右 dBm')]),
                        E('div',{id:'kk-latency-chart','class':'kk-chart kk-history-chart',role:'img','aria-label':'VPN 延迟与 LTE RSRP 信号历史，左轴毫秒、右轴 dBm，缺失记录留空'}),
                        E('div',{id:'kk-chart-times','class':'kk-chart-caption'},'正在读取历史…'),
                        E('label',{'class':'kk-footnote',for:'kk-history-cursor'},'在图表上移动或点击查看，亦可拖动下方时间滑块'),
                        E('input',{id:'kk-history-cursor',type:'range',min:0,max:1,value:1,'aria-label':'查看历史时刻',input:function(ev){self.inspectHistory(+ev.target.value);}}),
                        E('p',{id:'kk-history-detail','class':'kk-history-detail','aria-live':'polite'},'正在读取历史记录…'),
                        E('p',{id:'kk-history-note','class':'kk-footnote'},'记录从启用后开始积累；没有记录的时段保留空白。')
                    ]),
                    section('VPN 连通性 · 10.8.8.8','后台每 10 秒通过 VPN 检测一轮，关闭页面后仍会继续。',[
                        E('div',{'class':'kk-detail-grid'},[
                            E('div',{},[field('目标响应','—','kk-ping-state'),field('平均延迟','—','kk-ping-avg')]),
                            E('div',{},[field('本轮丢包率','—','kk-ping-loss'),field('延迟范围','—','kk-ping-range')])
                        ]),
                        E('p',{id:'kk-ping-time','class':'kk-footnote'},'等待首次检测…')
                    ]),
                    section('连接详情','接口接通不等于网站可访问，可用“检查网络”进一步确认。',[
                        E('div',{'class':'kk-detail-grid'},[
                            E('div',{},[field('当前出口地址','—','kk-wan-ip'),field('当前接口在线','—','kk-wan-uptime'),field('VPN 地址','—','kk-vpn-ip'),field('VPN 已连接','—','kk-vpn-age')]),
                            E('div',{},[field('设备运行','—','kk-uptime'),field('处理器温度','—','kk-temp'),field('可用内存','—','kk-memory'),field('VPN 累计收 / 发','—','kk-vpn-total'),field('树莓派 IPv6','—','kk-ipv6')])
                        ])
                    ]),
                    section('蜂窝网络 · F30A Pro','通过 ADB 每 30 秒读取；信号数据来自上网棒。',[
                        E('div',{'class':'kk-detail-grid'},[
                            E('div',{},[field('运营商','—','kk-modem-operator'),field('网络制式','—','kk-modem-network'),field('信号格数','—','kk-modem-bars'),field('LTE 信号 RSRP','—','kk-modem-rsrp')]),
                            E('div',{},[field('蜂窝连接','—','kk-modem-connected'),field('蜂窝连接时长','—','kk-modem-duration'),field('上网棒运行','—','kk-modem-uptime'),field('蜂窝接口累计收 / 发','—','kk-modem-bytes')])
                        ]),
                        E('p',{id:'kk-modem-time','class':'kk-footnote'},'尚未读取'),
                        E('div',{'class':'kk-actions'},[button('刷新上网棒状态',function(){self.perform('modem_refresh');}),E('a',{href:'http://192.168.0.1/',target:'_blank',rel:'noopener noreferrer'},'打开上网棒管理 ↗')]),
                        E('p',{'class':'kk-footnote'},'累计流量读取蜂窝接口计数，设备重启后可能归零，不是套餐用量或余量。RSRP 数值越接近 0，接收信号越强；实际速度还取决于网络拥塞。')
                    ]),
                    section('网络检查','从路由器分别探测线路，不修改当前分流。',[
                        E('div',{id:'kk-diagnostics'},E('p',{'class':'kk-empty'},'等待首次检查，也可点击右上方“检查网络”。')),
                        E('p',{id:'kk-diag-time','class':'kk-footnote'},'')
                    ]),
                    section('连接设备','无线设备为实时连接；其余为 DHCP 地址租约，不一定仍在线。',[
                        E('div',{id:'kk-devices','class':'kk-devices'},'正在读取…')
                    ])
                ]),
                E('aside',{'class':'kk-side'},[
                    section('VPN 控制','断网后会自动尝试恢复；长时间未恢复时可手动重连。',[
                        E('div',{'class':'kk-button-stack'},[vpnButton,pauseButton]),this.confirmArea,
                        E('form',{'class':'kk-auto-form',submit:function(ev){ev.preventDefault();self.request(saveAuto(self.auto.checked),'开机连接设置已保存。');}},[
                            E('label',{'class':'kk-check',for:'kk-auto'},[this.auto,E('span',{},'开机自动连接 VPN')]),
                            E('p',{'class':'kk-footnote'},'只影响下次开机，不会立即断开当前连接。'),
                            E('button',{type:'submit','class':'kk-button quiet'},'保存自动连接设置')
                        ]),
                        E('p',{'class':'kk-footnote',id:'kk-wg-note'},'原 WireGuard 已停用，配置保留。')
                    ]),
                    section('网口用途','LAN 接设备；WAN 接上级路由器，获取 IPv4 地址。',[
                        field('当前用途','—','kk-port-current'),field('有线连接','—','kk-port-link'),field('当前上网出口','—','kk-uplink-active'),
                        E('p',{id:'kk-port-health','class':'kk-footnote'},''),
                        E('form',{submit:function(ev){ev.preventDefault();self.changePort();}},[
                            E('label',{'class':'kk-field-label',for:'kk-port-mode'},'选择网口用途'),this.portMode,
                            E('p',{'class':'kk-footnote'},'WAN 使用 DHCP。有线探测正常后优先使用；断线或连续探测失败时回到 4G。切换会短暂中断网络，VPN 随出口重新连接。'),
                            E('label',{'class':'kk-check',for:'kk-port-ack'},[this.portAck,E('span',{},'我已通过 KK-Car Wi-Fi 管理，会在切换后 2 分钟内回来确认；未确认自动恢复。')]),
                            E('button',{type:'submit','class':'kk-button'},'保存网口用途')
                        ])
                    ]),
                    section('热点设置','修改后会短暂断开 Wi-Fi。',[
                        E('form',{submit:function(ev){ev.preventDefault();self.changeWifi();}},[
                            E('label',{'class':'kk-field-label',for:'kk-ssid'},'热点名称'),this.ssid,
                            E('label',{'class':'kk-field-label',for:'kk-band'},'Wi-Fi 频段'),this.band,
                            E('p',{'class':'kk-footnote'},'两个频段均使用 20MHz 带宽。内置无线只能选一个频段，切换会断开 Wi-Fi。'),
                            E('label',{'class':'kk-field-label',for:'kk-password'},'新密码'),this.password,
                            E('p',{'class':'kk-footnote'},'8–63 位字母、数字或符号。原密码不会显示。'),
                            E('label',{'class':'kk-check',for:'kk-wifi-ack'},[this.wifiAck,E('span',{},'我会重新连接热点，并在 2 分钟内返回确认；未确认会自动恢复。')]),
                            E('button',{type:'submit','class':'kk-button'},'保存热点设置')
                        ])
                    ]),
                    E('details',{'class':'kk-section kk-maintenance'},[
                        E('summary',{},'线路与维护'),E('div',{'class':'kk-details-body'},[
                            E('p',{},'重连上网棒会同时中断国内网络与 VPN，请先等待自动恢复，必要时再操作。'),
                            E('label',{'class':'kk-check',for:'kk-wan-ack'},[wanAck,E('span',{},'我已了解网络会短暂中断')]),wanButton,
                            E('dl',{'class':'kk-technical'},[
                                E('dt',{},'VPN 协议'),E('dd',{},'IKEv2 / IPsec'),
                                E('dt',{},'公司服务器'),E('dd',{id:'kk-server'},'—'),
                                E('dt',{},'VPN 路由'),E('dd',{id:'kk-route'},'—'),
                                E('dt',{},'热点频段 / 信道'),E('dd',{id:'kk-channel'},'—'),
                                E('dt',{},'管理地址'),E('dd',{},'192.168.88.1')
                            ]),
                            E('div',{'class':'kk-links'},[
                                E('a',{href:L.url('admin/network/network')},'网络高级设置 ↗'),
                                E('a',{href:L.url('admin/system/flash')},'备份 / 恢复配置 ↗'),
                                E('a',{href:'http://192.168.0.1/',target:'_blank',rel:'noopener noreferrer'},'上网棒管理 ↗')
                            ]),E('p',{'class':'kk-footnote'},'套餐余量请以运营商查询结果为准。')
                        ])
                    ])
                ])
            ]),
            E('div',{'class':'kk-footer',role:'contentinfo'},[E('span',{},'KK-Car 简易管理 · OpenWrt 25.12.5'),E('span',{},'设置保存在路由器上 · 飞书推送按开关启用')])
        );
        this.compactLayout();
        this.dashboardLayout();
        this.update(data);
        this.loadHistory(true);
        poll.add(function(){return self.refresh();},5);
        return this.root;
    },
    el:function(id){return this.root.querySelector('#'+id);},
    compactLayout:function(){
        // Move the existing live controls rather than duplicate them: IDs, event
        // handlers, confirmation flows and refresh targets remain unchanged.
        var main=this.root.querySelector('.kk-main'), side=this.root.querySelector('.kk-side');
        var sections=Array.from(this.root.querySelectorAll('section.kk-section'));
        function find(title){return sections.find(function(s){return s.querySelector('h2').textContent===title;});}
        function fold(title,nodes,className){return E('details',{'class':'kk-fold '+(className || '')},[E('summary',{},title),E('div',{'class':'kk-fold-body'},nodes)]);}
        var history=find('网络历史'), ping=find('VPN 连通性 · 10.8.8.8');
        history.classList.add('kk-history-section');
        history.querySelector('.kk-section-head p').textContent='后台持续记录 · 流量与 VPN 延迟';
        var tools=E('div',{'class':'kk-history-toolbar'},[history.querySelector('.kk-traffic-numbers'),history.querySelector('.kk-history-ranges')]);
        history.querySelector('.kk-section-head').after(tools);
        var pingStrip=E('div',{'class':'kk-ping-strip','aria-label':'VPN 实时检测'});
        Array.from(ping.querySelectorAll('.kk-data-row')).forEach(function(row){pingStrip.append(row);});
        tools.after(pingStrip);
        var plots=E('div',{'class':'kk-plots'});
        ['kk-chart','kk-latency-chart'].forEach(function(id){
            var chart=history.querySelector('#'+id),heading=chart.previousElementSibling;
            plots.append(E('div',{'class':'kk-plot'},[heading,chart]));
        });
        pingStrip.after(plots);
        history.querySelector('label[for="kk-history-cursor"]').textContent='拖动查看历史时刻';
        var notes=fold('采样与保存说明',[this.el('kk-history-note')]);
        history.append(E('div',{'class':'kk-history-meta'},[E('span',{id:'kk-history-brief'},'正在读取…'),this.el('kk-ping-time')]),notes);
        ping.remove();
        find('连接详情').classList.add('kk-connection-section');
        var modem=find('蜂窝网络 · F30A Pro');modem.classList.add('kk-modem-section');
        modem.querySelector('.kk-section-head p').textContent='上网棒实时状态 · 每 30 秒更新';
        modem.append(fold('信号与流量说明',[modem.lastElementChild]));
        find('连接设备').querySelector('.kk-section-head p').textContent='Wi-Fi 在线设备与 DHCP 租约';
        find('网络检查').querySelector('.kk-section-head p').textContent='自动与手动检查结果';
        var vpn=find('VPN 控制');
        vpn.querySelector('.kk-section-head p').textContent='断线后自动恢复，必要时手动重连';
        vpn.append(fold('开机连接与旧 VPN',[vpn.querySelector('form'),this.el('kk-wg-note')]));
        var port=find('网口用途');
        port.querySelector('.kk-section-head p').remove();
        port.append(fold('切换 LAN / WAN',[this.el('kk-port-health'),port.querySelector('form')]));
        var wifi=find('热点设置'), wifiFold=fold('热点名称、频段与密码',Array.from(wifi.children).filter(function(n){return !n.classList.contains('kk-section-head');}),'kk-settings-fold');
        wifi.replaceWith(wifiFold);
        var checks=find('网络检查');
        this.diagnosticFold=fold('上次网络检查',Array.from(checks.children).filter(function(n){return !n.classList.contains('kk-section-head');}),'kk-settings-fold');
        this.diagnosticFold.querySelector('summary').id='kk-diag-summary';
        checks.remove();side.append(this.diagnosticFold,find('连接设备'));
        side.setAttribute('aria-label','网络控制与设置');main.classList.add('kk-dense-main');
    },
    text:function(id,text){this.el(id).textContent=text;},
    dashboardLayout:function(){
        var self=this, columns=this.root.querySelector('.kk-columns'),side=this.root.querySelector('.kk-side');
        var history=this.root.querySelector('.kk-history-section');
        function moveField(label,id,title){
            var value=self.el(id);if(!value) value=E('strong',{id:id},'—');
            var oldRow=value.closest('.kk-data-row'),oldTerm=value.tagName==='DD'?value.previousElementSibling:null;
            var field=E('div',{'class':'kk-instrument',title:title || label},[E('span',{},label),value]);
            if(oldRow) oldRow.remove();if(oldTerm && oldTerm.tagName==='DT') oldTerm.remove();
            return field;
        }
        function group(title,rows){return E('section',{'class':'kk-instrument-group'},[E('h2',{},title),E('div',{'class':'kk-instruments'},rows.map(function(r){return moveField(r[0],r[1],r[2]);}))]);}
        var instruments=E('div',{'class':'kk-instrument-board'},[
            group('系统 / CPU',[
                ['CPU 占用','kk-cpu','所有 CPU 核心的平均忙碌比例，按最近两次采样的计数差计算'],['实际频率','kk-clock'],
                ['负载 1 / 5 / 15 分','kk-load','系统运行队列负载，不是 CPU 百分比'],['连接跟踪','kk-conntrack','当前连接跟踪条目数 / 容量，不是在线设备数'],
                ['可用 / 总内存','kk-memory'],['处理器温度','kk-temp'],['运行时间','kk-uptime'],['供电 / 降频','kk-throttle']]),
            group('出口 / 接口',[
                ['出口地址','kk-wan-ip'],['接口在线','kk-wan-uptime'],['累计收 / 发','kk-total','上网接口的累计字节数，不是套餐余量'],
                ['包数 收 / 发','kk-packets'],['累计错误 / 丢弃','kk-errors','当前上网接口的收发错误总数 / 收发丢弃总数，累计值，不是本轮丢包率'],
                ['出口 MTU','kk-wan-mtu'],['有线网口','kk-port-current'],['树莓派 IPv6','kk-ipv6']]),
            group('VPN / IPsec',[
                ['隧道地址','kk-vpn-ip'],['已连接','kk-vpn-age'],['本 SA 收 / 发','kk-vpn-total','当前 IPsec SA 的字节计数，重新换钥后会归零'],
                ['隧道 MTU','kk-vpn-mtu'],['ESP 加密','kk-cipher'],['CHILD 换钥剩余','kk-rekey'],
                ['接口累计错 / 丢','kk-vpn-errors','VPN 虚拟接口累计收发错误 / 丢弃，不等于当前 Ping 丢包率'],['分流路由','kk-route']]),
            group('蜂窝 / F30A Pro',[
                ['运营商','kk-modem-operator'],['网络制式','kk-modem-network'],['LTE RSRP','kk-modem-rsrp'],['信号格数','kk-modem-bars'],
                ['蜂窝连接','kk-modem-connected'],['连接时长','kk-modem-duration'],['上网棒运行','kk-modem-uptime'],['累计收 / 发','kk-modem-bytes']])
        ]);
        var deviceSection=Array.from(side.querySelectorAll('section')).find(function(s){return s.querySelector('h2')?.textContent==='连接设备';});
        // Expand former disclosure panels into ordinary sections. Keep every live
        // node and handler, including safety acknowledgements, in the same page.
        function unfold(detail,title){
            var summary=detail.querySelector(':scope > summary'), body=detail.querySelector(':scope > div');
            var heading=E('h2',summary.id?{id:summary.id}:{},title || summary.textContent);
            var panel=E('section',{'class':'kk-section kk-open-panel'},[E('div',{'class':'kk-section-head'},[heading])].concat(Array.from(body.children)));
            detail.replaceWith(panel);return panel;
        }
        var diagnostics=unfold(this.diagnosticFold,'网络检查');
        var vpn=side.querySelector('section'),port=Array.from(side.querySelectorAll('section')).find(function(s){return s.querySelector('h2')?.textContent==='网口用途';});
        [vpn,port].forEach(function(panel){var d=panel.querySelector('details');d.replaceWith(...Array.from(d.querySelector('.kk-fold-body').children));});
        var wifi=unfold(side.querySelector('.kk-settings-fold'),'热点设置');
        var maintenance=unfold(side.querySelector('.kk-maintenance'),'线路与维护');
        maintenance.querySelector('p').textContent='重连上网棒会中断网络与 VPN。';
        port.querySelector('form > p').textContent='WAN 自动获取地址，有线正常时优先；断线回到 4G，VPN 随出口重连。';
        port.querySelector('.kk-check span').textContent='已通过 Wi-Fi 管理；切换后 2 分钟内确认，未确认自动恢复。';
        var wifiNotes=wifi.querySelectorAll('form > p');
        wifiNotes[0].textContent='20 MHz 带宽；切换频段会断开 Wi-Fi。';
        wifiNotes[1].textContent='8–63 位；留空保留原密码。';
        wifi.querySelector('.kk-check span').textContent='重连后 2 分钟内确认，未确认自动恢复。';
        vpn.querySelector('.kk-auto-form .kk-footnote').textContent='仅影响下次开机。';
        vpn.querySelector('button[type=submit]').textContent='保存开机设置';
        var modem=this.root.querySelector('.kk-modem-section');
        var notes=E('section',{'class':'kk-inline-notes'},[
            history.querySelector('#kk-history-note'),this.el('kk-modem-time'),modem.querySelector('.kk-actions'),
            E('p',{'class':'kk-footnote'},'RSRP 越接近 0，信号越强。流量为接口累计，重启可能归零；套餐余量以运营商为准。')
        ]);
        var workspace=E('div',{'class':'kk-workspace'},[
            E('main',{'class':'kk-monitor'},[history,instruments,E('div',{'class':'kk-bottom-grid'},[deviceSection,diagnostics])]),
            E('aside',{'class':'kk-controls','aria-label':'网络控制与设置'},[
                E('div',{'class':'kk-control-column'},[vpn,port,notes]),
                E('div',{'class':'kk-control-column'},[wifi,maintenance])
            ])
        ]);
        history.querySelector('.kk-traffic-total').remove();
        history.querySelector('.kk-fold').remove();
        history.querySelector('.kk-section-head').remove();
        var top=this.root.querySelector('.kk-overview'),status=top.querySelector('.kk-overview-top');
        this.root.querySelector('.kk-header').append(this.el('kk-summary'),status.querySelector('.kk-actions'));
        status.remove();
        top.append(E('span',{id:'kk-summary-desc',hidden:true},''));
        columns.replaceWith(workspace);
        this.root.classList.add('kk-console','kk-fullscreen','kk-studio');
    },
    message:function(text,error){var el=this.el('kk-message');el.hidden=false;el.textContent=text;el.className='kk-notice '+(error?'error':'');},
    refresh:function(){
        var self=this;
        return getStatus().then(function(data){self.update(data);self.loadHistory(false);}).catch(function(){
            self.connectionLost=true;
            self.text('kk-refreshed','连接中断 · 数据未更新');
            self.message('暂时无法连接路由器，下面保留的是上次状态。若刚修改热点，请重新连接；页面会自动重试。',true);
            self.root.classList.add('kk-stale');
        });
    },
    request:function(promise,message,kind){
        var self=this; this.requesting=true;this.setBusy(true);
        return promise.then(function(res){
            if(!res.ok) throw new Error(res.error || '保存失败，请刷新后重试');
            self.message(res.unchanged?'设置没有变化。':message,false);
            return self.refresh().then(function(){
                // Fast read-only jobs can finish before the first status response.
                if(kind && !self.data.busy && self.data.job.kind===kind && self.data.job.state!=='running')
                    self.message(self.data.job.message,self.data.job.state==='error');
            });
        }).catch(function(err){self.message(err.message || '无法连接路由器，请稍后重试',true);})
        .finally(function(){self.requesting=false;self.setBusy(self.data && self.data.busy);});
    },
    perform:function(kind){
        if(this.requesting || this.data.busy) return;
        var words={modem_refresh:'正在读取上网棒状态…',diagnose:'正在检查网络与 AI 地区，约需 15 秒…',vpn_restart:'正在重新连接 VPN…',vpn_start:'正在启动 VPN…',vpn_stop:'正在暂停 VPN…',wan_restart:'正在重新连接上网棒，请等待网络恢复…'};
        this.confirmArea.hidden=true;
        this.request(action(kind),words[kind],kind);
    },
    changeWifi:function(){
        var name=this.ssid.value, pass=this.password.value;
        if(!name || new TextEncoder().encode(name).length>32){this.message('热点名称不能为空，最多 32 字节（中文通常每字 3 字节）。',true);return;}
        if(pass && (pass.length<8 || pass.length>63 || /[^\x20-\x7e]/.test(pass))){this.message('密码请使用 8–63 位英文字母、数字或常用符号。',true);return;}
        if(!this.wifiAck.checked && (name!==this.data.wifi.ssid || pass || this.band.value!==this.data.wifi.band)){this.message('请先勾选重新连接及自动回退说明。',true);return;}
        var self=this;
        this.request(saveWifi(name,pass,this.band.value),'热点设置已提交，请连接新热点后返回本页确认。').then(function(){self.password.value='';self.wifiAck.checked=false;});
    },
    changePort:function(){
        var mode=this.portMode.value, current=this.data.ethernet && this.data.ethernet.mode || 'lan';
        if(mode!==current && !this.portAck.checked){this.message('请先通过 KK-Car Wi-Fi 连接，并勾选切换确认说明。',true);return;}
        var self=this;
        this.request(savePort(mode),'网口用途已提交，请保持 Wi-Fi 连接并返回确认。').then(function(){self.portAck.checked=false;});
    },
    setBusy:function(busy){
        this.root.querySelectorAll('button').forEach(function(b){
            if(b.closest('#kk-pending') || b.closest('#kk-port-pending')) b.disabled=false;
            else b.disabled=!!busy;
        });
    },
    tone:function(id,tone){this.el(id).dataset.tone=tone;},
    update:function(d){
        if(!d || !d.wan || !d.vpn) throw new Error('状态数据不可用');
        var self=this, old=this.data;this.data=d;this.root.classList.remove('kk-stale');
        if(this.connectionLost){this.connectionLost=false;this.message('已重新连接路由器，状态已更新。',false);}
        this.text('kk-refreshed','更新于 '+stamp(d.timestamp));
        this.text('kk-summary',!d.wan.up?'上网出口未接通':d.vpn.connected?'VPN 已连接':d.vpn.running?'VPN 正在连接':'VPN 已暂停');
        this.tone('kk-summary',!d.wan.up?'bad':d.vpn.connected?'good':d.vpn.running?'warning':'neutral');
        this.tone('kk-wan-status',d.wan.up?'good':'bad');
        this.tone('kk-vpn-status',d.vpn.connected?'good':d.vpn.running?'warning':'neutral');
        this.tone('kk-wifi-name',d.wifi.frequency?'good':'warning');
        this.text('kk-summary-desc',!d.wan.up?'请检查网线、USB 连接、蜂窝信号和供电。':d.vpn.connected?'国内直连，国外和公司内网经过 VPN。实际访问请看网络检查结果。':d.vpn.running?'国内可直连，VPN 正在尝试恢复，国外访问暂时暂停。':'国内可直连，启动 VPN 后恢复国外和公司内网访问。');
        var uplink=d.uplink || {}, port=d.ethernet || {}, uplinkName=uplink.active==='ethernet'?'有线 WAN':uplink.active==='none'?'暂无出口':'4G 上网棒';
        this.text('kk-wan-status',d.wan.up?uplinkName:'未接通');
        this.text('kk-wan-detail',d.wan.ip || '等待获取地址');
        this.text('kk-port-current',port.mode==='wan'?'WAN · 有线优先':'LAN · 内网接口');
        this.text('kk-port-link',port.carrier?(port.mode==='wan'?(port.ip || '等待获取地址'):'已接网线'):'未接网线');
        this.text('kk-uplink-active',uplinkName);
        var reasons={lan:'网口与 Wi-Fi 属于同一内网，连接电脑可自动分配地址。',no_cable:'等待有线网络，目前使用 4G。',dhcp_wait:'已接网线，正在等待上级路由器分配地址。',subnet_conflict:'有线网段与车内 LAN 或上网棒重叠，暂不启用；请更换上级路由器的网段。',preferred:'有线网络探测通过，优先用于国内直连和 VPN 上联。',checking:'正在连续检测有线网络，稳定后自动切换。',probe_failed:'有线网络未通过互联网探测，使用 4G 备用。'};
        this.text('kk-port-health',!uplink.timestamp || d.timestamp-uplink.timestamp>30?'出口检测未更新，请检查后台服务。':!uplink.ready?'出口路由需要检查。':reasons[uplink.reason] || '正在读取出口状态。');
        this.text('kk-vpn-status',d.vpn.connected?'隧道已建立':d.vpn.running?'正在连接':'已暂停');
        this.text('kk-vpn-detail',d.vpn.ip || '未获得 VPN 地址');
        var probe=d.vpn_ping || {}, probeAge=d.uptime-probe.uptime;
        var probeFresh=probe.timestamp && probeAge>=0 && probeAge<=25;
        var probeValid=probeFresh && d.vpn.connected;
        var probeNames={ok:'可达',loss:'可达 · 有丢包',timeout:'未响应',vpn_down:'VPN 未连接',error:'检测异常'};
        this.text('kk-ping-state',!d.vpn.connected?'VPN 未连接':!probeFresh?(probe.timestamp?'检测已过期':'正在检测'):probeNames[probe.state] || '检测异常');
        this.el('kk-ping-state').className=probeValid && probe.state==='ok'?'kk-good':'kk-bad';
        this.text('kk-ping-avg',probeValid && probe.avg_ms!=null?probe.avg_ms.toFixed(1)+' ms':'—');
        this.text('kk-ping-loss',probeValid && probe.loss_percent!=null?probe.loss_percent.toFixed(0)+'% · '+probe.received+'/'+probe.sent+' 次响应':'—');
        this.text('kk-ping-range',probeValid && probe.min_ms!=null && probe.max_ms!=null?probe.min_ms.toFixed(1)+'–'+probe.max_ms.toFixed(1)+' ms':'—');
        this.tone('kk-ping-loss',probeValid && probe.loss_percent!=null?(probe.loss_percent===0?'good':'bad'):'neutral');
        this.text('kk-ping-time',probe.timestamp?'VPN 检测 '+stamp(probe.timestamp):'等待 VPN 首次检测');
        this.text('kk-wifi-name',d.wifi.ssid);
        var activeBand=d.wifi.frequency>=5000?'5 GHz':d.wifi.frequency>=2400?'2.4 GHz':'热点未启动';
        this.text('kk-wifi-detail',activeBand+(d.wifi.width?' · '+d.wifi.width+' MHz':'')+' · '+d.wifi.clients+' 台无线设备');
        this.text('kk-ipv6',d.ipv6_disabled?'已关闭 · 无地址及路由':'需要检查');
        var modem=d.modem || {}, fresh=modem.online && d.timestamp-modem.timestamp<75;
        var metric=function(value,suffix){return fresh && value!=null?value+suffix:'—';};
        this.text('kk-modem-operator',fresh?(modem.operator==='China Telecom'?'中国电信':modem.operator || '未读到'):'—');
        this.text('kk-modem-network',fresh?(modem.network==='LTE'?'4G · LTE':modem.network || '未读到'):'—');
        this.text('kk-modem-bars',metric(modem.bars,' / 5 格'));
        this.text('kk-modem-rsrp',fresh && /LTE/i.test(modem.network || '')?metric(modem.rsrp,' dBm'):'—');
        this.text('kk-modem-connected',fresh?(modem.connected?'已连接':'未连接'):'状态未更新');
        this.text('kk-modem-duration',fresh && modem.connection_uptime!=null?duration(modem.connection_uptime):'—');
        this.text('kk-modem-uptime',fresh?duration(modem.uptime):'—');
        this.text('kk-modem-bytes',fresh && modem.rx!=null && modem.tx!=null?bytes(modem.rx)+' / '+bytes(modem.tx):'—');
        this.text('kk-modem-time',fresh?'读取于 '+stamp(modem.timestamp)+' · ADB 已连接':modem.timestamp?'ADB 暂未连通或数据已过期 · 最后尝试 '+stamp(modem.timestamp)+'；这不代表蜂窝网络已断开。':'正在等待首次读取上网棒…');
        this.text('kk-wan-ip',d.wan.ip || '—');this.text('kk-wan-uptime',duration(d.wan.uptime));
        this.text('kk-vpn-ip',d.vpn.ip || '未分配');this.text('kk-vpn-age',d.vpn.connected?duration(d.vpn.age):'未连接');
        this.text('kk-uptime',duration(d.uptime));this.text('kk-temp',d.temperature?d.temperature.toFixed(1)+' °C':'未读到');
        var telemetry=d.telemetry || {}, cpu=telemetry.cpu || {}, previousCpu=old && old.telemetry && old.telemetry.cpu;
        var cpuPercent=null;
        if(previousCpu && d.uptime>old.uptime && d.uptime-old.uptime<=20 && cpu.total>previousCpu.total && cpu.idle>=previousCpu.idle)
            cpuPercent=Math.max(0,Math.min(100,100*(1-(cpu.idle-previousCpu.idle)/(cpu.total-previousCpu.total))));
        this.text('kk-cpu',cpuPercent==null?'采样中':cpuPercent.toFixed(1)+'%');
        this.text('kk-clock',cpu.mhz==null?'未知':Math.round(cpu.mhz)+' MHz');
        this.text('kk-load',(telemetry.loads || []).map(function(v){return v==null?'—':v;}).join(' / ') || '未知');
        this.text('kk-conntrack',telemetry.conntrack==null?'未知':telemetry.conntrack.toLocaleString()+' / '+(telemetry.conntrack_max==null?'未知':telemetry.conntrack_max.toLocaleString()));
        this.text('kk-throttle',!d.power.known?'未知':(d.power.undervoltage?'欠压':'未报欠压')+' / '+(d.power.throttled?'降频':'未降频'));
        this.tone('kk-throttle',!d.power.known?'neutral':d.power.undervoltage || d.power.throttled?'warning':'good');
        this.tone('kk-modem-connected',!fresh?'neutral':modem.connected?'good':'bad');
        var wireStats=telemetry.wan || {}, vpnStats=telemetry.vpn || {};
        function statsPair(stats,a,b){return stats[a]==null || stats[b]==null?'未知':stats[a].toLocaleString()+' / '+stats[b].toLocaleString();}
        function errors(stats){return ['rx_errors','tx_errors','rx_dropped','tx_dropped'].some(function(k){return stats[k]==null;})?'未知':(stats.rx_errors+stats.tx_errors).toLocaleString()+' / '+(stats.rx_dropped+stats.tx_dropped).toLocaleString();}
        this.text('kk-packets',statsPair(wireStats,'rx_packets','tx_packets'));
        this.text('kk-errors',errors(wireStats));this.text('kk-vpn-errors',errors(vpnStats));
        this.text('kk-wan-mtu',wireStats.mtu==null?'未知':wireStats.mtu+' B');this.text('kk-vpn-mtu',vpnStats.mtu==null?'未知':vpnStats.mtu+' B');
        this.text('kk-cipher',telemetry.cipher?telemetry.cipher.split('/')[0].replace('AES_CBC-','AES-')+' CBC':'未建立');
        this.el('kk-cipher').parentElement.title=telemetry.cipher || '当前没有已建立的 CHILD SA';
        this.text('kk-rekey',telemetry.rekey==null?'未建立':duration(telemetry.rekey));
        this.text('kk-memory',bytes(d.memory && d.memory.available)+' / '+bytes(d.memory && d.memory.total));
        this.text('kk-vpn-total',bytes(d.vpn.rx)+' / '+bytes(d.vpn.tx));
        this.text('kk-total',bytes(d.wan.rx)+' / '+bytes(d.wan.tx));
        this.text('kk-server',d.vpn.server);this.text('kk-route',d.vpn.route?'已就绪':'需要检查');
        this.text('kk-channel',activeBand+' / '+d.wifi.channel+(d.wifi.width?' / '+d.wifi.width+' MHz':''));
        this.text('kk-wg-note',d.wg_enabled?'WireGuard 已被高级设置启用，请检查是否与当前 VPN 冲突。':'原 WireGuard 已停用，配置保留。');
        this.el('kk-power').hidden=!(d.power.undervoltage || d.power.throttled);
        this.text('kk-power-text',d.power.undervoltage?'当前检测到欠压，可能引起降速或掉线。请检查电源和供电线。':'当前检测到处理器降频，请检查温度及供电。');
        var pending=d.wifi_pending;
        this.el('kk-pending').hidden=!pending;
        if(pending) this.text('kk-pending-text','请连接「'+pending.ssid+'」后确认。剩余约 '+Math.max(0,pending.deadline-d.timestamp)+' 秒，未确认会恢复原设置。');
        var portpending=d.port_pending;
        this.el('kk-port-pending').hidden=!portpending;
        if(portpending) this.text('kk-port-pending-text','目标用途：'+portpending.mode.toUpperCase()+'。请通过 Wi-Fi 确认仍能管理。剩余约 '+Math.max(0,portpending.deadline-d.timestamp)+' 秒，未确认会恢复原用途。');
        var paused=!d.vpn.running;
        this.el('kk-reconnect').textContent=paused?'启动 VPN':'重新连接 VPN';
        this.el('kk-pause').hidden=paused;
        if(old && old.busy && !d.busy && d.job.message) this.message(d.job.message,d.job.state==='error');
        if(d.busy && !this.requesting && !pending && !portpending) this.message('操作进行中，请稍候。页面会自动更新结果。',false);
        this.setBusy(d.busy || this.requesting);
        var dev=this.el('kk-devices');dev.replaceChildren();
        if(!d.peers.length) dev.appendChild(E('p',{'class':'kk-empty'},'暂未发现设备地址记录。'));
        d.peers.forEach(function(peer){dev.appendChild(E('div',{'class':'kk-device'},[
            E('div',{},[E('strong',{},peer.name),E('span',{},peer.ip)]),
            E('span',{'class':'kk-device-state '+(peer.wireless?'online':'')},peer.wireless?'Wi-Fi 已连接':'地址租约')
        ]));});
        var result=d.diagnostics, autoCheck=d.diagnostics_auto || {};
        var autoActive=autoCheck.enabled && d.timestamp>=autoCheck.updated && d.timestamp-autoCheck.updated<=45;
        var autoLabel=autoActive?'每10分钟自动检查':'手动检查';
        this.text('kk-diag-time',autoLabel+(autoActive?' · 下次约 '+stamp(autoCheck.next_run):''));
        if(result.timestamp){
            var diag=this.el('kk-diagnostics');diag.replaceChildren();
            [['国内出口',result.domestic,result.domestic_detail || '目标未响应'],['VPN 出口',result.foreign,result.foreign_ip?result.foreign_ip+' · '+result.foreign_country:'目标未响应'],['公司服务',result.company,'10.8.8.15:8080 · HTTP '+result.company_code],['国外域名解析',result.dns,'www.google.com']].forEach(function(row){
                diag.appendChild(E('div',{'class':'kk-check-result'},[E('div',{},[E('strong',{},row[0]),E('span',{},row[2])]),E('b',{'class':row[1]?'kk-good':'kk-bad'},row[1]?'通过':'未通过')]));
            });
            ['chatgpt','gemini'].forEach(function(name){
                var a=result[name] || {}, country=a.country;
                var names={CN:'中国大陆',JP:'日本',US:'美国',SG:'新加坡',HK:'中国香港',TW:'中国台湾',GB:'英国',DE:'德国',KR:'韩国',AU:'澳大利亚',CA:'加拿大'};
                var region=country?(names[country]?names[country]+' '+country:country):'地区未知';
                var source=name==='chatgpt'?'边缘地区':'页面地区（参考）';
                var state=a.state, label=state==='cn'?'中国 CN':state==='non_cn'?'非 CN':!a.http_code?'未测得':'待确认';
                var reason=!result[name]?'点击检查获取':a.reason==='timeout'?'请求超时':a.reason==='response_too_large'?'页面超过上限':a.transport==='error'?'连接未完成':a.http_code?'HTTP '+a.http_code:'无响应';
                var tip=(name==='chatgpt'?'chatgpt.com/cdn-cgi/trace 的 loc，代表该域名的 Cloudflare 边缘地区，不等于账号或模型可用性。':'gemini.google.com 页面 vXmutd 地区字段，是页面内部参考信号，格式变化时会显示地区未知。')+' 所有请求均从树莓派通过 VPN 发出；手机定位、账号地区及设备自己的代理可能影响实际使用。';
                diag.appendChild(E('div',{'class':'kk-check-result kk-ai-result','title':tip},[
                    E('div',{},[E('strong',{},name==='chatgpt'?'ChatGPT':'Gemini'),E('span',{},region+' · '+reason),E('small',{},source)]),
                    E('b',{'class':state==='cn'?'kk-bad':state==='non_cn'?'kk-good':'kk-unknown'},label)
                ]));
            });
            this.text('kk-diag-summary','网络检查 '+[result.domestic,result.foreign,result.company,result.dns].filter(Boolean).length+'/4 · 地区 '+[result.chatgpt,result.gemini].filter(function(a){return a && a.country;}).length+'/2 已识别');
            this.text('kk-diag-time',autoLabel+' · 检查于 '+stamp(result.timestamp)+' · 地区结果不代表账号可用。');
        }
        if(this.previous && d.timestamp>this.previous.timestamp){
            var dt=d.timestamp-this.previous.timestamp;
            var rx=Math.max(0,d.wan.rx-this.previous.wan.rx)*8/dt/1e6,tx=Math.max(0,d.wan.tx-this.previous.wan.tx)*8/dt/1e6;
            if(dt<=20 && d.wan.rx>=this.previous.wan.rx && d.wan.tx>=this.previous.wan.tx) {
                
                this.text('kk-rx-speed',rx.toFixed(2));this.text('kk-tx-speed',tx.toFixed(2));
            } else {this.text('kk-rx-speed','—');this.text('kk-tx-speed','—');}
        }
        this.previous=d;
    },
    loadHistory:function(force){
        var self=this, now=Date.now(), range=this.historyRange;
        var interval=range==='30d'?300000:range==='1d'?60000:30000;
        if(!force && (this.historyLoading || now-this.historyFetched<interval)) return;
        var request=++this.historyRequest;this.historyLoading=true;
        this.root.querySelectorAll('[data-range]').forEach(function(b){b.setAttribute('aria-pressed',b.dataset.range===range?'true':'false');});
        if(force) {this.text('kk-history-note','正在读取所选范围…');this.text('kk-history-brief','正在读取历史…');}
        getHistory(range).then(function(h){
            if(request!==self.historyRequest) return;
            if(!h.ok) throw new Error(h.error || '读取失败');
            self.historyData=h;self.historyFetched=Date.now();self.drawHistory();
        }).catch(function(){if(request===self.historyRequest) {self.text('kk-history-note','历史读取失败；当前图表保留上一次结果，稍后自动重试。');self.text('kk-history-brief','历史读取失败，保留上次图表');}})
        .finally(function(){if(request===self.historyRequest) self.historyLoading=false;});
    },
    historyTime:function(t){return new Date(t*1000).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});},
    inspectHistory:function(index){
        var h=this.historyData;if(!h) return;
        index=Math.max(0,Math.min(h.points.length-1,index));var p=h.points[index];
        this.el('kk-history-cursor').value=index;
        var detail=this.historyTime(p[0])+' · ';
        if(!p[8]) detail+='没有采集记录';
        else {
            detail+='下载 '+(p[1]==null?'未采集':p[1].toFixed(2)+' Mbps')+' / 上传 '+(p[2]==null?'未采集':p[2].toFixed(2)+' Mbps');
            detail+=' · VPN '+(p[3]==null?'无有效响应':p[3].toFixed(1)+' ms（'+p[6].toFixed(1)+'–'+p[7].toFixed(1)+' ms）');
            detail+=' · '+(p[4]?'丢包 '+((p[4]-p[5])*100/p[4]).toFixed(1)+'%':'未发送 Ping');
            detail+=' · 信号 '+(p[10]==null?'无记录':p[10].toFixed(1)+' dBm（'+p[11]+' 次）');
            detail+=' · '+p[8]+' 轮检测';
        }
        this.text('kk-history-detail',detail);
        this.el('kk-history-cursor').setAttribute('aria-valuetext',detail);
        this.root.querySelectorAll('.kk-chart-cursor').forEach(function(line){var width=+(line.closest('svg').getAttribute('data-plot-width') || 590),x=42+(p[0]-h.from)/(h.to-h.from)*width;line.setAttribute('x1',x);line.setAttribute('x2',x);});
    },
    drawHistory:function(){
        var self=this,h=this.historyData, samples=h.points;
        function draw(id,series,unit,signalAxis){
            var box=self.el(id), width=signalAxis?548:590,end=42+width;
            var upper=Math.max(unit==='ms'?10:.1,...samples.flatMap(function(p){return series.filter(function(s){return s[1]!=='signal';}).map(function(s){return p[s[0]] || 0;});}))*1.1;
            var svg=svgNode('svg',{viewBox:'0 0 640 130',preserveAspectRatio:'none','aria-hidden':'true','data-plot-width':width});
            [0,.5,1].forEach(function(f){
                var y=112-f*96;svg.appendChild(svgNode('line',{x1:42,x2:end,y1:y,y2:y,'class':'kk-grid-line'}));
                var text=svgNode('text',{x:36,y:y+3,'text-anchor':'end','class':'kk-axis-label'+(signalAxis?' kk-axis-latency':'')});text.textContent=(upper*f).toFixed(unit==='ms'?0:2);svg.appendChild(text);
                if(signalAxis){var label=svgNode('text',{x:end+8,y:y+3,'text-anchor':'start','class':'kk-axis-label kk-axis-signal'});label.textContent=-150+120*f;svg.appendChild(label);}
            });
            series.forEach(function(s){
                var points=[],count=samples.filter(function(p){return p[s[0]]!=null;}).length;
                function flush(){if(points.length>1) svg.appendChild(svgNode('polyline',{points:points.join(' '),fill:'none','class':'kk-line-'+s[1],'stroke-width':2,'vector-effect':'non-scaling-stroke'}));points=[];}
                samples.forEach(function(p){
                    var x=42+(p[0]-h.from)/(h.to-h.from)*width;
                    if(p[s[0]]==null){flush();if(s[1]==='latency' && p[8]) svg.appendChild(svgNode('circle',{cx:x,cy:112,r:2.2,'class':'kk-missing-dot'}));return;}
                    var y=s[1]==='signal'?112-(p[s[0]]+150)/120*96:112-p[s[0]]/upper*96;points.push(x+','+y);
                    svg.appendChild(svgNode('circle',{cx:x,cy:y,r:count<3?3:1.2,'class':'kk-dot-'+s[1]}));
                });flush();
            });
            if(signalAxis && !samples.some(function(p){return p[10]!=null;})) {
                var empty=svgNode('text',{x:316,y:127,'text-anchor':'middle','class':'kk-axis-label kk-axis-signal'});empty.textContent='本范围暂无信号记录';svg.appendChild(empty);
            }
            svg.appendChild(svgNode('line',{x1:end,x2:end,y1:10,y2:114,'class':'kk-chart-cursor'}));
            box.replaceChildren(svg);
            function inspect(ev){var rect=box.getBoundingClientRect(),x=(ev.clientX-rect.left)/rect.width*640;var t=h.from+Math.max(0,Math.min(1,(x-42)/width))*(h.to-h.from);self.inspectHistory(Math.round((t-h.points[0][0])/h.step));}
            box.onpointermove=inspect;box.onpointerdown=inspect;
        }
        draw('kk-chart',[[1,'rx'],[2,'tx']],'Mbps',false);draw('kk-latency-chart',[[3,'latency'],[10,'signal']],'ms',true);
        this.el('kk-chart-times').replaceChildren(E('span',{},this.historyTime(h.from)),E('span',{},this.historyTime(h.to)));
        var resolution=h.step===60?'每分钟':h.step===300?'每 5 分钟':'每小时';
        var stale=!h.last_sample || this.data.timestamp-h.last_sample>30;
        this.text('kk-history-brief',(h.storage_error?'保存失败 · ':stale?'采集未更新 · ':'')+resolution+'汇总 · 已有 '+h.minutes+' 分钟记录');
        this.text('kk-history-note',(h.storage_error?'保存到 SD 卡失败，目前仅保留内存记录。':stale?'后台采集暂未更新。':'')+resolution+'汇总 · 本范围已有 '+h.minutes+' 分钟记录'+(h.first?'，始于 '+this.historyTime(h.first):'，等待首次采样')+'。曲线为平均值；空白无记录，红点为 VPN 无响应。信号从启用后记录，越接近 0 越强。每 5 分钟保存，断电最多丢失约 6 分钟。');
        this.el('kk-history-cursor').max=samples.length-1;
        var latest=samples.length-1;while(latest>0 && !samples[latest][8]) latest--;
        this.inspectHistory(latest);
    }
});
