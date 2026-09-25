'use strict';
'require view';
'require rpc';
'require poll';

var get=rpc.declare({object:'kkups',method:'status',expect:{}});
function number(v,dec){return Number.isFinite(v)?Number(v).toFixed(dec):'—';}
function volts(mv){return Number.isFinite(mv)?number(mv/1000,2)+' V':'—';}
function duration(s){if(!Number.isFinite(s))return '—';var h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h>0?h+' 小时 '+m+' 分钟':m+' 分钟';}
function cell(label,value,hint){var children=[E('span',{},label),E('strong',{},value)];if(hint)children.push(E('small',{},hint));return E('div',{'class':'ku-cell'},children);}
function section(title,nodes,subtitle){var heading=[E('h2',{},title)];if(subtitle)heading.push(E('span',{},subtitle));return E('section',{'class':'ku-panel'},[E('div',{'class':'ku-panel-title'},heading),E('div',{'class':'ku-grid'},nodes)]);}
function nav(href,title,active){return E('a',{href:href,'class':'ku-nav-item'+(active?' active':'')},title);}

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return get();},
    render:function(data){
        document.title='KK-Car · UPS 电源';
        if(!document.getElementById('kk-ups-css'))
            document.head.appendChild(E('link',{id:'kk-ups-css',rel:'stylesheet',href:L.resource('view/kkcar/ups.css')}));
        var self=this;
        this.hero=E('div',{'class':'ku-hero-main'});
        this.warnings=E('div',{'class':'ku-warnings'});
        this.metrics=E('div',{'class':'ku-metrics'});
        this.updated=E('span',{'class':'ku-updated'});
        this.refresh=E('button',{'class':'ku-button',type:'button',click:function(){self.refresh.disabled=true;get().then(function(r){self.paint(r);}).catch(function(){self.showError('无法读取 UPS 状态');}).finally(function(){self.refresh.disabled=false;});}},'立即刷新');
        var root=E('div',{'class':'ku-shell'},[
            E('aside',{'class':'ku-sidebar'},[
                E('div',{'class':'ku-brand'},[E('b',{},'KK'),E('span',{},'CAR CONTROL')]),
                E('div',{'class':'ku-nav'},[
                    nav(L.url('admin/kkcar'),'网络总览',false),
                    nav(L.url('admin/kkcar_dji'),'DJI 4G',false),
                    nav(L.url('admin/kkcar_ups'),'UPS 电源',true),
                    nav(L.url('admin/kkcar_notifications'),'飞书推送',false)]),
                E('p',{'class':'ku-sidebar-note'},'52Pi UPS Plus · EP-0136\n树莓派 3B+ / OpenWrt')
            ]),
            E('main',{'class':'ku-main'},[
                E('header',{'class':'ku-header'},[E('div',{},[E('span',{'class':'ku-eyebrow'},'POWER SYSTEM / 01'),E('h1',{},'UPS 电源管理'),E('p',{},'实时查看输入、电池、树莓派供电与控制器状态')]),E('div',{'class':'ku-header-actions'},[this.updated,this.refresh])]),
                E('section',{'class':'ku-hero'},[this.hero,this.warnings]),
                this.metrics,
                E('div',{'class':'ku-foot'},[E('span',{},'电量百分比需完成至少一次完整充放电后才可校准。'),E('span',{},'本页每 10 秒更新；不修改网络、VPN 或 UPS 固件。')])
            ])
        ]);
        this.paint(data);
        poll.add(function(){return get().then(function(r){self.paint(r);}).catch(function(){self.showError('UPS 状态暂时无法读取');});},10);
        return root;
    },
    showError:function(message){this.hero.replaceChildren(E('div',{'class':'ku-error'},message));this.warnings.replaceChildren();this.metrics.replaceChildren();this.updated.textContent='读取失败';},
    paint:function(d){
        if(!d || !d.ok){this.showError(d&&d.error?d.error:'UPS 未响应');return;}
        var b=d.battery||{},i=d.input||{},o=d.output||{},c=d.controller||{},s=d.sensors||{};
        var pct=Number.isFinite(b.percent)?Math.min(100,Math.max(0,b.percent)):0;
        this.updated.textContent='更新于 '+new Date(d.timestamp*1000).toLocaleTimeString('zh-CN',{hour12:false});
        this.hero.replaceChildren(
            E('div',{'class':'ku-battery'},[
                E('div',{'class':'ku-battery-top'},[E('span',{},'BATTERY / 电池电量估计'),E('span',{'class':'ku-pill '+(i.external?'good':'warn')},i.external?'外部供电中':'电池供电中')]),
                E('div',{'class':'ku-battery-value'},[E('strong',{},number(b.percent,0)),E('span',{},'%')]),
                E('div',{'class':'ku-gauge',role:'meter','aria-label':'电池电量估计','aria-valuemin':'0','aria-valuemax':'100','aria-valuenow':String(pct)},E('div',{style:'width:'+pct+'%'})),
                E('p',{},'电量为 UPS 估算值，未完成完整充放电前不用于判断剩余续航。')
            ]),
            E('div',{'class':'ku-hero-stats'},[
                cell('树莓派供电',volts(o.pogo_mv),o.pi_undervoltage===true?'当前欠压':o.pi_undervoltage===false?'当前无欠压':'欠压状态未知'),
                cell('电池端电压',volts(b.millivolts),'UPS 主控读数'),
                cell('电池温度',number(b.temperature_c,0)+' °C',b.temperature_c>=50?'注意散热 · 硬件保护阈值 65°C':'硬件保护阈值 65°C')
            ])
        );
        this.warnings.replaceChildren.apply(this.warnings,(d.warnings||[]).map(function(w){return E('div',{'class':'ku-warning'},w);}));
        this.metrics.replaceChildren(
            section('输入电源',[cell('USB-C 输入',volts(i.usb_c_mv),i.usb_c_mv>=4400?'已接入':'未接入'),cell('Micro-USB 输入',volts(i.micro_usb_mv),i.micro_usb_mv>=4400?'已接入':'未接入'),cell('外部电源',i.external?'已接入':'未检测到','依照端口电压判断')]),
            section('树莓派与电池',[cell('UPS 输出',volts(o.pogo_mv),'Pogo Pin 供电端'),cell('UPS 主控电压',volts(o.mcu_mv)),cell('当前欠压',o.pi_undervoltage===null?'未知':o.pi_undervoltage?'是':'否'),cell('本次启动曾欠压',o.pi_undervoltage_history===null?'未知':o.pi_undervoltage_history?'是':'否'),cell('当前降频',o.pi_throttled===null?'未知':o.pi_throttled?'是':'否'),cell('电池温度',number(b.temperature_c,0)+' °C')],'电流传感器尚未校准，暂不展示电流和功率'),
            section('UPS 控制器',[cell('固件版本',String(c.version)),cell('运行状态',c.powered?'开启':'关闭'),cell('采样周期',number(c.sample_minutes,0)+' 分钟'),cell('来电自启',c.auto_start_on_ac?'开启':'关闭','只读显示，暂不改写设备设置'),cell('本次运行',duration(c.current_run_s)),cell('累计运行',duration(c.total_run_s)),cell('累计充电',duration(c.charging_s)),cell('关机倒计时',c.shutdown_countdown_s?c.shutdown_countdown_s+' 秒':'未设置'),cell('重启倒计时',c.restart_countdown_s?c.restart_countdown_s+' 秒':'未设置')]),
            section('硬件连接',[cell('UPS 主控','已连接','I²C 0x17'),cell('树莓派供电传感器',s.pi_supply?'已检测':'未检测','I²C 0x40'),cell('电池传感器',s.battery?'已检测':'未检测','I²C 0x45'),cell('实时时钟',s.rtc?'已检测':'未检测','I²C 0x68')],'检测到 RTC 不代表系统时间已由其校准')
        );
    }
});
