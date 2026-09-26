'use strict';
'require view';
'require rpc';
'require poll';

var get=rpc.declare({object:'kkups',method:'status',expect:{}});
var setOption=rpc.declare({object:'kkups',method:'set_option',params:['key','value','expected','confirm'],expect:{}});
var savePolicy=rpc.declare({object:'kkups',method:'save_policy',params:['enabled','shutdown_mv'],expect:{}});
var syncRtc=rpc.declare({object:'kkups',method:'rtc_sync',expect:{}});
var powerAction=rpc.declare({object:'kkups',method:'power_action',params:['action','confirm'],expect:{}});
function number(v,dec){return Number.isFinite(v)?Number(v).toFixed(dec):'—';}
function volts(mv){return Number.isFinite(mv)?number(mv/1000,2)+' V':'—';}
function millivolts(mv){return Number.isFinite(mv)?number(mv,0)+' mV':'—';}
function duration(s){if(!Number.isFinite(s))return '—';var h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h>0?h+' 小时 '+m+' 分钟':m+' 分钟';}
function yesno(v){return v==null?'未知':v?'是':'否';}
function watchLabel(v){return ({disabled:'未启用',monitoring:'监测中',external_power:'外部供电中',on_battery:'电池供电中',low_battery_wait:'低电压复核中',low_battery:'已触发低电关机',read_error:'采样失败',invalid_voltage:'电压读数无效'})[v]||'等待首次采样';}
function cell(label,value,hint){var children=[E('span',{},label),E('strong',{},value)];if(hint)children.push(E('small',{},hint));return E('div',{'class':'ku-cell'},children);}
function section(title,nodes,subtitle){var heading=[E('h2',{},title)];if(subtitle)heading.push(E('span',{},subtitle));return E('section',{'class':'ku-panel'},[E('div',{'class':'ku-panel-title'},heading),E('div',{'class':'ku-grid'},nodes)]);}
function nav(href,title,active){return E('a',{href:href,'class':'ku-nav-item'+(active?' active':''),'aria-current':active?'page':null},title);}

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return get();},
    render:function(data){
        document.title='KK-Car · UPS 电源';
        if(!document.getElementById('kk-ups-css'))
            document.head.appendChild(E('link',{id:'kk-ups-css',rel:'stylesheet',href:L.resource('view/kkcar/ups.css')+'?v=20260925-ui3'}));
        var self=this;
        this.hero=E('div',{'class':'ku-hero-main'});
        this.warnings=E('div',{'class':'ku-warnings'});
        this.metrics=E('div',{'class':'ku-metrics'});
        this.quickControls=E('div',{'class':'ku-controls ku-quick-controls'});
        this.controls=E('div',{'class':'ku-controls'});
        this.notice=E('div',{'class':'ku-notice',hidden:true,role:'status','aria-live':'polite'});
        this.controlsReady=false;
        this.updated=E('span',{'class':'ku-updated'});
        this.refresh=E('button',{'class':'ku-button',type:'button',click:function(){self.refresh.disabled=true;get().then(function(r){self.paint(r);}).catch(function(){self.showError('无法读取 UPS 状态');}).finally(function(){self.refresh.disabled=false;});}},'立即刷新');
        var root=E('div',{'class':'ku-shell'},[
            E('aside',{'class':'ku-sidebar'},[
                E('div',{'class':'ku-brand'},[E('b',{},'KK'),E('span',{},'CAR CONTROL')]),
                E('div',{'class':'ku-nav'},[
                    nav(L.url('admin/kkcar'),'行车总览',false),
                    nav(L.url('admin/kkcar_connections'),'连接设置',false),
                    nav(L.url('admin/kkcar_dji'),'蜂窝与通信',false),
                    nav(L.url('admin/kkcar_ups'),'电源与设备',true),
                    nav(L.url('admin/kkcar_notifications'),'通知中心',false)]),
                E('p',{'class':'ku-sidebar-note'},'52Pi UPS Plus · EP-0136\n树莓派 3B+ / OpenWrt')
            ]),
            E('main',{'class':'ku-main'},[
                E('header',{'class':'ku-header'},[E('div',{},[E('span',{'class':'ku-eyebrow'},'POWER SYSTEM / 01'),E('h1',{},'UPS 电源管理'),E('p',{},'实时查看输入、电池、树莓派供电与控制器状态')]),E('div',{'class':'ku-header-actions'},[this.updated,this.refresh])]),
                this.notice,
                E('section',{'class':'ku-hero'},[this.hero,this.warnings]),
                this.quickControls,
                this.metrics,
                this.controls,
                E('div',{'class':'ku-foot'},[E('span',{},'电量百分比需完成至少一次完整充放电后才可校准。'),E('span',{},'本页每 10 秒更新；设置只在点击保存后写入 UPS。')])
            ])
        ]);
        this.paint(data);
        poll.add(function(){return get().then(function(r){self.paint(r);}).catch(function(){self.showError('UPS 状态暂时无法读取');});},10);
        return root;
    },
    showError:function(message){this.hero.replaceChildren(E('div',{'class':'ku-error'},message));this.warnings.replaceChildren();this.metrics.replaceChildren();this.quickControls.replaceChildren();this.controls.replaceChildren();this.controlsReady=false;this.updated.textContent='读取失败';},
    message:function(text,error){this.notice.hidden=false;this.notice.className='ku-notice'+(error?' error':'');this.notice.textContent=text;},
    perform:function(promise,success,rebuild){
        var self=this;if(this.busy)return Promise.resolve();this.busy=true;
        return promise.then(function(r){if(!r||!r.ok)throw Error(r&&r.error||'操作失败');self.message(success||'设置已保存',false);return get().then(function(d){if(rebuild){self.controlsReady=false;self.quickControls.replaceChildren();self.controls.replaceChildren();}self.paint(d);});})
            .catch(function(e){self.message(e.message||'操作失败',true);})
            .finally(function(){self.busy=false;});
    },
    saveOption:function(key,value,expected,battery){
        if(!Number.isInteger(value)){this.message('请输入整数设置值',true);return;}
        var confirm='';
        if(battery){confirm=window.prompt('修改电池参数可能影响电量估算和保护阈值。请确认外部电源稳定，输入“修改电池参数”：')||'';if(confirm!=='修改电池参数')return;}
        this.perform(setOption(key,value,expected,confirm),'设备设置已写入并读回',true);
    },
    controlRow:function(label,key,value,min,max,description,battery,checkbox){
        var self=this,input=E('input',{type:checkbox?'checkbox':'number',min:min,max:max,step:1,'aria-label':label});
        if(checkbox)input.checked=!!value;else input.value=value;
        return E('div',{'class':'ku-setting'},[E('div',{},[E('strong',{},label),E('small',{},description)]),input,
            E('button',{'class':'ku-button',type:'button',click:function(){self.saveOption(key,checkbox?(input.checked?1:0):Number(input.value),value,battery);}},'保存')]);
    },
    buildControls:function(d){
        var self=this,b=d.battery,c=d.controller,p=d.policy||{enabled:false,shutdown_mv:3550};
        var policyOn=E('input',{type:'checkbox','aria-label':'启用低电安全关机'});policyOn.checked=!!p.enabled;
        var policyMv=E('input',{type:'number',min:3300,max:3900,step:10,value:p.shutdown_mv,'aria-label':'低电关机阈值 mV'});
        function action(label,key,phrase,description){return E('div',{'class':'ku-action'},[E('div',{},[E('strong',{},label),E('small',{},description)]),E('button',{'class':'ku-button'+(phrase?' danger':''),type:'button',click:function(){var answer=phrase?(window.prompt('此操作会改变设备供电状态。请输入“'+phrase+'”确认：')||''):'';if(phrase&&answer!==phrase)return;self.perform(powerAction(key,answer),key.startsWith('cancel')?'倒计时取消指令已发送':'操作指令已发送',true);}},label)]);}
        this.quickControls.replaceChildren(
            E('div',{'class':'ku-controls-title'},[E('h2',{},'常用设置'),E('p',{},'仅点击保存后写入；低电保护默认关闭。')]),
            E('div',{'class':'ku-settings-grid'},[
                E('section',{'class':'ku-panel'},[E('h3',{},'日常设置'),
                    this.controlRow('来电自启','auto_start_on_ac',c.auto_start_on_ac?1:0,0,1,'外部电源恢复后自动启动',false,true),
                    this.controlRow('采样周期','sample_minutes',c.sample_minutes,1,1440,'1–1440 分钟；当前设备为 '+c.sample_minutes+' 分钟',false,false),
                    E('div',{'class':'ku-setting'},[E('div',{},[E('strong',{},'RTC 校时'),E('small',{},'将已校准的系统 UTC 时间写入 UPS 时钟')]),E('button',{'class':'ku-button',type:'button',click:function(){if(window.confirm('确认用树莓派当前系统时间同步 UPS 实时时钟？'))self.perform(syncRtc(),'RTC 已与系统时间同步',true);}},'同步时间')])]),
                E('section',{'class':'ku-panel'},[E('h3',{},'低电安全关机'),E('p',{'class':'ku-helper'},'外部输入断开时监测参考电压。两路读数差异超过 150 mV 时回退主控读数并告警；连续 3 次低于阈值才安排 UPS 180 秒后断电，并让 OpenWrt 正常关机。电量百分比不参与判断，低压段仍需实测核对。'),
                    E('div',{'class':'ku-setting'},[E('div',{},[E('strong',{},'启用监控'),E('small',{},'断电后持续监测电池电压')]),policyOn]),
                    E('div',{'class':'ku-setting'},[E('div',{},[E('strong',{},'关机阈值'),E('small',{},'3300–3900 mV；需按实际电池与负载校准')]),policyMv,E('button',{'class':'ku-button',type:'button',click:function(){var mv=Number(policyMv.value);if(!Number.isInteger(mv)){self.message('请输入整数电压',true);return;}if(policyOn.checked&&!p.enabled&&!window.confirm('启用后，当车载外部供电断开且电池持续低电压时，树莓派会自动关机。确定启用？'))return;self.perform(savePolicy(policyOn.checked,mv),'低电保护设置已保存',true);}},'保存策略')]),
                    E('small',{'class':'ku-watch'},'监控状态：'+watchLabel(d.watch&&d.watch.status)+' · 连续低电样本 '+((d.watch&&d.watch.consecutive)||0)+'/3')])
            ])
        );
        this.controls.replaceChildren(
            E('div',{'class':'ku-controls-title'},[E('h2',{},'高级维护'),E('p',{},'电池基准和供电操作会影响设备稳定性，请核对后再执行。')]),
            E('div',{'class':'ku-settings-grid'},[
                E('section',{'class':'ku-panel'},[E('h3',{},'电池参数 · 高级'),E('p',{'class':'ku-helper'},'仅在确认电池型号及外部供电稳定时修改。当前原值已显示；改动需输入确认文字。'),
                    this.controlRow('满电基准','full_mv',b.configured_full_mv,4000,4500,'4000–4500 mV',true,false),
                    this.controlRow('空电基准','empty_mv',b.configured_empty_mv,2500,3900,'2500–3900 mV；当前值可能低于可设置范围',true,false),
                    this.controlRow('电池保护电压','protect_mv',b.configured_protect_mv,2750,3900,'2750–3900 mV；读到 0 不代表保护关闭，旧固件可能回退 3600 mV',true,false),
                    this.controlRow('用户电池参数','user_programmed',b.user_programmed?1:0,0,1,'自动模式允许空电与保护相等；手动模式必须留出差值，避免旧固件钳位电压影响保护',true,true)]),
                E('section',{'class':'ku-panel ku-maintenance'},[E('h3',{},'电源操作 · 高级'),E('p',{'class':'ku-helper'},'执行后可能失去远程连接。正常关机与 UPS 重启会先安排 180 秒倒计时，再让系统正常停止；恢复出厂先在设备私有目录保存现有参数。'),
                    action('重启树莓派','reboot_pi','重启树莓派','UPS 保持供电，仅重启 OpenWrt'),
                    action('安全关机','shutdown','关闭树莓派','UPS 将在倒计时后切断输出'),
                    action('UPS 电源循环重启','restart_ups','重启UPS','系统先正常关机，再由 UPS 恢复供电'),
                    action('取消关机倒计时','cancel_shutdown','','仅取消已安排的 UPS 关机倒计时'),
                    action('取消重启倒计时','cancel_restart','','仅取消已安排的 UPS 重启倒计时'),
                    action('恢复 UPS 出厂参数','factory_reset','恢复出厂','可能覆盖当前电池参数；操作前保留私有备份'),
                    E('p',{'class':'ku-helper'},'固件 OTA 不是普通开关：需要匹配固件与断电恢复条件，未开放网页刷写。')])
            ])
        );
        this.controlsReady=true;
    },
    paint:function(d){
        if(!d||!d.ok){this.showError(d&&d.error?d.error:'UPS 未响应');return;}
        var b=d.battery||{},i=d.input||{},o=d.output||{},c=d.controller||{},s=d.sensors||{},pi=s.pi_supply||{},bat=s.battery||{},rtc=s.rtc||{},diag=d.diagnostics||{},ref=d.voltage_reference||{};
        var pct=Number.isFinite(b.percent)?Math.min(100,Math.max(0,b.percent)):0;
        this.updated.textContent='更新于 '+new Date(d.timestamp*1000).toLocaleTimeString('zh-CN',{hour12:false});
        this.hero.replaceChildren(
            E('div',{'class':'ku-battery'},[E('div',{'class':'ku-battery-top'},[E('span',{},'BATTERY / 电池电量估计'),E('span',{'class':'ku-pill '+(i.external?'good':'warn')},i.external?'外部供电中':'电池供电中')]),E('div',{'class':'ku-battery-value'},[E('strong',{},number(b.percent,0)),E('span',{},'%')]),E('div',{'class':'ku-gauge',role:'meter','aria-label':'电池电量估计','aria-valuemin':'0','aria-valuemax':'100','aria-valuenow':String(pct)},E('div',{style:'width:'+pct+'%'})),E('p',{},'UPS 估算值；未确认完成完整充放电校准，不据此推算续航。')]),
            E('div',{'class':'ku-hero-stats'},[cell('树莓派供电',volts(o.pogo_mv),o.pi_undervoltage===true?'当前欠压':o.pi_undervoltage===false?'当前无欠压':'欠压状态未知'),cell('树莓派耗电估算',number(pi.power_mw/1000,1)+' W','来自 INA219 电压差及厂商标注电阻'),cell('电池温度',number(b.temperature_c,0)+' °C',b.temperature_c>=50?'注意散热 · 硬件保护 65°C':'硬件保护 65°C')])
        );
        this.warnings.replaceChildren.apply(this.warnings,(d.warnings||[]).map(function(w){return E('div',{'class':'ku-warning'},w);}));
        this.metrics.replaceChildren(
            section('输入与树莓派供电',[cell('USB-C 输入',volts(i.usb_c_mv),i.usb_c_mv>=4400?'已接入':'未接入'),cell('Micro-USB 输入',volts(i.micro_usb_mv),i.micro_usb_mv>=4400?'已接入':'未接入'),cell('UPS 输出',volts(o.pogo_mv),'Pogo Pin 端'),cell('Pi 侧传感器电压',volts(pi.bus_mv),'INA219 0x40'),cell('Pi 估算电流',number(pi.current_ma,0)+' mA','采样电阻 0.00725 Ω'),cell('Pi 估算功率',number(pi.power_mw/1000,2)+' W','未用外部仪表校准'),cell('Pi 采样电阻压降',number(pi.shunt_uv/1000,2)+' mV'),cell('UPS 主控电压',volts(o.mcu_mv))]),
            section('电池与充放电',[cell('UPS 电池端',volts(b.millivolts),'主控读数'),cell('电池侧传感器电压',volts(bat.bus_mv),ref.sensor_rejected?'差异明显 · 暂不用作低电判断':'INA219 0x45'),cell('低电判断参考',volts(ref.millivolts),(ref.source==='battery_sensor'?'电池侧 INA219':ref.source==='controller'?'UPS 主控':'无有效读数')+' · '+(d.policy&&d.policy.enabled?'策略已启用':'策略关闭')),cell('两路电压差',millivolts(ref.difference_mv),'150 mV 为一致性检查界限'),cell('电池估算电流',number(bat.current_ma,0)+' mA',bat.current_ma>50?'正值约定为充电':bat.current_ma< -50?'负值约定为放电':'接近平衡'),cell('电池估算功率',number(bat.power_mw/1000,2)+' W','依据 INA219 采样电阻'),cell('电池采样电阻压降',number(bat.shunt_uv/1000,2)+' mV'),cell('电池温度',number(b.temperature_c,0)+' °C'),cell('满电基准',millivolts(b.configured_full_mv)),cell('空电基准',millivolts(b.configured_empty_mv)),cell('保护电压',millivolts(b.configured_protect_mv))],'估算电流/功率采用厂商标注电阻值，尚未外部校准'),
            section('UPS 控制器',[cell('固件版本',String(c.version)),cell('设备序列号',c.serial||'—','仅登录管理员可见'),cell('运行状态',c.powered?'开启':'关闭'),cell('采样周期',number(c.sample_minutes,0)+' 分钟'),cell('来电自启',c.auto_start_on_ac?'开启':'关闭'),cell('用户电池参数',b.user_programmed?'启用':'未启用'),cell('本次运行',duration(c.current_run_s)),cell('累计运行',duration(c.total_run_s)),cell('累计充电',duration(c.charging_s)),cell('关机倒计时',c.shutdown_countdown_s?c.shutdown_countdown_s+' 秒':'未设置'),cell('重启倒计时',c.restart_countdown_s?c.restart_countdown_s+' 秒':'未设置')]),
            section('时钟与硬件诊断',[cell('故障记录',diag.ok&&d.timestamp>=diag.timestamp&&d.timestamp-diag.timestamp<90?'每分钟保存中':'尚未更新','SD 卡保留 · 总量上限 16 MB'),cell('最近一分钟 QMI 错误',number(diag.qmi_errors,0),'超时及响应解析失败次数'),cell('本次启动未正常卸载告警',number(diag.sd_unclean,0),'启动分区 FAT 告警次数'),cell('RTC',rtc.detected?(rtc.halted?'停振 / 待校时':rtc.valid?'运行中':'时间无效'):'未检测','I²C 0x68'),cell('RTC 寄存器时间',rtc.time_register||'—','手动同步后为 UTC'),cell('UPS 主控','已连接','I²C 0x17'),cell('Pi 侧 INA219',pi.detected?'已检测':'未检测','I²C 0x40 · 校准 '+(pi.calibration??'—')),cell('电池侧 INA219',bat.detected?'已检测':'未检测','I²C 0x45 · 校准 '+(bat.calibration??'—')),cell('Pi 传感器状态',pi.overflow?'量程溢出':pi.conversion_ready?'转换完成':'等待转换','配置 0x'+(pi.config==null?'—':pi.config.toString(16))),cell('电池传感器状态',bat.overflow?'量程溢出':bat.conversion_ready?'转换完成':'等待转换','配置 0x'+(bat.config==null?'—':bat.config.toString(16))),cell('CPU 温度',number(o.cpu_temperature_c,1)+' °C'),cell('树莓派供电标志',o.power_flags==null?'未知':'0x'+o.power_flags.toString(16)),cell('当前欠压 / 降频',yesno(o.pi_undervoltage)+' / '+yesno(o.pi_throttled)),cell('当前限频 / 软温控',yesno(o.pi_frequency_capped)+' / '+yesno(o.pi_soft_temp_limit)),cell('曾欠压 / 降频',yesno(o.pi_undervoltage_history)+' / '+yesno(o.pi_throttled_history)),cell('曾限频 / 软温控',yesno(o.pi_frequency_capped_history)+' / '+yesno(o.pi_soft_temp_limit_history))],'RTC 时间可手动从系统写入；电流与功率为未外部校准的估算值')
        );
        if(!this.controlsReady)this.buildControls(d);
    }
});
