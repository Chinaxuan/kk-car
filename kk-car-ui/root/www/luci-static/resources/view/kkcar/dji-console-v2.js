'use strict';
'require view';
'require rpc';
'require poll';

var getNetwork = rpc.declare({object:'kkcar',method:'status',expect:{}});
var getDji = rpc.declare({object:'kkdji',method:'status',expect:{}});
var djiAction = rpc.declare({object:'kkdji',method:'action',params:['action'],expect:{}});
var smsList = rpc.declare({object:'kkdji',method:'sms_list',expect:{}});
var smsRead = rpc.declare({object:'kkdji',method:'sms_read',params:['index'],expect:{}});
var smsSend = rpc.declare({object:'kkdji',method:'sms_send',params:['to','text'],expect:{}});
var smsDelete = rpc.declare({object:'kkdji',method:'sms_delete',params:['index'],expect:{}});
var voiceProbe = rpc.declare({object:'kkdji',method:'voice_probe',expect:{}});
var callStatus = rpc.declare({object:'kkdji',method:'call_status',expect:{}});
var callDial = rpc.declare({object:'kkdji',method:'call_dial',params:['number'],expect:{}});
var callAnswer = rpc.declare({object:'kkdji',method:'call_answer',expect:{}});
var callHangup = rpc.declare({object:'kkdji',method:'call_hangup',expect:{}});
var voiceTicket = rpc.declare({object:'kkdji',method:'voice_ticket',expect:{}});
var gpsProbe = rpc.declare({object:'kkdji',method:'gps_probe',expect:{}});
var trafficStatus = rpc.declare({object:'kkdji',method:'traffic_status',expect:{}});
var trafficSave = rpc.declare({object:'kkdji',method:'traffic_save',params:['operator','recipient','command','daily','hour'],expect:{}});
var trafficQuery = rpc.declare({object:'kkdji',method:'traffic_query',expect:{}});

function own(value, key) { return value && Object.prototype.hasOwnProperty.call(value,key) ? value[key] : null; }
function first() { for (var i=0;i<arguments.length;i++) if (arguments[i] !== null && arguments[i] !== undefined && arguments[i] !== '') return arguments[i]; return null; }
function shown(value, empty) { return value === null || value === undefined || value === '' ? (empty || '—') : String(value).slice(0,120); }
function metric(value, unit, digits) { var n=Number(value); return value === null || value === undefined || value === '' || !isFinite(n) ? '—' : n.toFixed(digits || 0)+(unit || ''); }
function size(value) { var n=Number(value), units=['B','KB','MB','GB','TB'], i=0; if(value === null || value === undefined || !isFinite(n) || n < 0) return '—'; while(n>=1024 && i<4){n/=1024;i++;} return n.toFixed(i ? 1 : 0)+' '+units[i]; }
function clock(value) { var n=Number(value); return n>0 && isFinite(n) ? new Date(n*1000).toLocaleString('zh-CN',{hour12:false}) : '尚未读取'; }
function ago(value) { var n=Number(value); if(!(n>0))return '尚未读取'; var s=Math.max(0,Math.floor(Date.now()/1000-n)); return s<60?s+' 秒前':s<3600?Math.floor(s/60)+' 分钟前':Math.floor(s/3600)+' 小时前'; }
function duration(value) { var n=Number(value); if(!isFinite(n) || n<0 || value==null)return '—'; return n>=3600?Math.floor(n/3600)+' 小时 '+Math.floor(n%3600/60)+' 分钟':Math.floor(n/60)+' 分 '+Math.floor(n%60)+' 秒'; }
function row(label,id){return E('div',{'class':'kk-dji-row'},[E('span',{},label),E('strong',{id:id},'—')]);}
function card(title,desc,body,extra){return E('section',{'class':'kk-dji-card'+(extra?' '+extra:'')},[E('div',{'class':'kk-dji-card-head'},[E('h2',{},title),desc?E('p',{},desc):''])].concat(body));}
function button(label,handler,extra){return E('button',{type:'button','class':'kk-button '+(extra || ''),click:handler},label);}
function simLabel(value){return ({ready:'可用',absent:'未插入 SIM',pin_required:'需要 PIN',puk_required:'需要 PUK',blocked:'已锁定'})[value] || '未检测';}
function registerLabel(value){return ({registered:'已注册',searching:'正在搜索',not_registered:'未注册','not-registered':'未注册',denied:'注册被拒'})[value] || '未检测';}
function signalTone(value,good,usable,weak){
    var n=Number(value);
    if(value===null || value===undefined || value==='' || !isFinite(n))return 'unknown';
    return n>=good?'good':n>=usable?'usable':n>=weak?'weak':'poor';
}

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return Promise.all([getNetwork(),getDji().catch(function(){return null;}),trafficStatus().catch(function(){return null;})]).then(function(results){return {network:results[0],device:results[1],traffic:results[2]};});},
    render:function(data){
        var self=this;
        document.title='KK-Car · DJI 4G';
        ['overview','dji-console-v2'].forEach(function(name){var id='kk-css-'+name;if(!document.getElementById(id))document.head.appendChild(E('link',{id:id,rel:'stylesheet',href:L.resource('view/kkcar/'+name+'.css')}));});
        this.notice=E('div',{'class':'kk-notice',role:'status','aria-live':'polite',hidden:true});
        this.summary=E('strong',{id:'kk-dji-summary'},'读取中');
        this.refreshButton=button('刷新状态',function(){self.refresh(true);});
        this.reconnectButton=button('重连 DJI 数据网络',function(){self.reconnect();},'primary');
        this.smsListButton=button('刷新短信',function(){self.readSmsList();});
        this.voiceProbeButton=button('检测电话能力',function(){self.checkVoice();});
        this.voiceStatus=E('p',{'class':'kk-dji-note','aria-live':'polite'},'尚未检测电话接口与音频。检测只读，不会拨号或重启模块。');
        this.callNumber=E('input',{type:'tel',inputmode:'tel',autocomplete:'off',maxlength:16,placeholder:'输入要拨打的号码','aria-label':'拨打号码'});
        this.callDialButton=button('拨号',function(){self.phoneDial();},'primary');
        this.callAnswerButton=button('接听',function(){self.phoneAnswer();},'primary');
        this.callHangupButton=button('挂断',function(){self.phoneHangup();},'danger');
        this.httpsPhoneButton=button('用 HTTPS 打开电话',function(){window.location.href='https://'+window.location.host+window.location.pathname;});
        this.httpsPhoneButton.hidden=window.isSecureContext===true;
        this.callDialButton.disabled=this.callAnswerButton.disabled=this.callHangupButton.disabled=true;
        this.voiceReady=false;this.voiceBusy=false;this.currentCall=null;this.audioSocket=null;
        this.trafficOperator=E('select',{'aria-label':'运营商',change:function(){self.trafficPreset();}},[
            E('option',{value:'CT'},'中国电信'),E('option',{value:'CMCC'},'中国移动'),E('option',{value:'CU'},'中国联通')]);
        this.trafficRecipient=E('input',{type:'text',inputmode:'numeric',maxlength:6,'aria-label':'短信查询号码'});
        this.trafficCommand=E('input',{type:'text',maxlength:20,'aria-label':'短信查询指令'});
        this.trafficDaily=E('input',{type:'checkbox','aria-label':'每天自动查询'});
        this.trafficHour=E('select',{'aria-label':'每天查询时间'},Array.from({length:24},function(_,i){return E('option',{value:String(i)},String(i).padStart(2,'0')+':00');}));
        this.trafficSaveButton=button('保存查询设置',function(){self.saveTraffic();});
        this.trafficQueryButton=button('现在查询并校正',function(){self.queryTraffic();},'primary');
        this.smsSearch=E('input',{type:'search','class':'kk-dji-sms-search',placeholder:'搜索号码、时间或状态',autocomplete:'off',input:function(){self.renderSmsItems();}});
        this.smsDetailMeta=E('div',{'class':'kk-dji-sms-detail-meta'},'选择左侧短信查看正文');
        this.smsDetailBody=E('div',{'class':'kk-dji-sms-detail-body','aria-live':'polite'},'正文只在你点击短信后读取，不保存在浏览器。');
        this.smsClearButton=button('清除当前内容',function(){self.clearSmsDetail();});
        this.smsDeleteButton=button('删除这条短信',function(){self.deleteSelectedSms();},'danger');
        this.smsReplyButton=button('回复这条',function(){self.replySelectedSms();});
        this.smsReplyButton.disabled=true;
        this.smsDeleteButton.disabled=true;
        this.gpsStartButton=button('启动定位',function(){self.performGps('gps_start');});
        this.gpsStopButton=button('停止定位',function(){self.performGps('gps_stop');});
        this.gpsProbeButton=button('刷新定位',function(){self.readGps(true);});
        this.to=E('input',{id:'kk-dji-sms-to',type:'tel',inputmode:'tel',autocomplete:'off',maxlength:20,placeholder:'接收号码'});
        this.text=E('textarea',{id:'kk-dji-sms-text',rows:3,maxlength:70,placeholder:'单条最多 70 字；仅点击发送后提交给模块。'});
        this.smsForm=E('form',{'class':'kk-dji-sms-form',submit:function(ev){ev.preventDefault();self.sendSms();}},[
            E('label',{for:'kk-dji-sms-to'},'接收号码'),this.to,
            E('label',{for:'kk-dji-sms-text'},'短信内容'),this.text,
            E('div',{'class':'kk-dji-actions'},[E('span',{'class':'kk-muted'},'单条 UCS2 最多 70 字，不支持 emoji；发送可能产生费用。'),E('button',{type:'submit','class':'kk-button primary'},'发送短信')])
        ]);
        this.smsListArea=E('div',{'class':'kk-dji-sms-list','aria-live':'polite'},'正在自动读取短信…');
        this.smsItems=[];this.selectedSmsIndex=null;
        this.root=E('div',{'class':'kk-app kk-studio kk-dji'},[
            E('header',{'class':'kk-header'},[
                E('div',{'class':'kk-brand'},[E('span',{'class':'kk-monogram','aria-hidden':'true'},'DJ'),E('div',{},[E('h1',{},'DJI 4G 模块'),E('p',{},'蜂窝线路 · 信号、连接与模块控制')])]),
                E('div',{'class':'kk-header-links'},[E('span',{id:'kk-dji-update'},'读取中'),E('a',{href:L.url('admin/kkcar')},'返回网络面板'),E('a',{href:L.url('admin/kkcar_notifications')},'飞书推送')])
            ]),
            this.notice,
            E('section',{'class':'kk-dji-hero'},[
                E('div',{'class':'kk-dji-hero-title'},[E('div',{},[E('div',{'class':'kk-dji-eyebrow'},'CELLULAR / DJI'),this.summary,E('p',{id:'kk-dji-description'},'正在读取模块状态…')]),this.refreshButton]),
                E('div',{'class':'kk-dji-phase'},[
                    E('div',{},[E('span',{},'SIM 卡'),E('strong',{id:'kk-dji-sim'},'—')]),
                    E('div',{},[E('span',{},'运营商网络'),E('strong',{id:'kk-dji-register'},'—')]),
                    E('div',{},[E('span',{},'数据会话'),E('strong',{id:'kk-dji-session'},'—')]),
                    E('div',{},[E('span',{},'当前上网出口'),E('strong',{id:'kk-dji-uplink'},'—')])
                ])
            ]),
            E('div',{'class':'kk-dji-grid'},[
                card('无线信号','经验参考阈值；通话和网络稳定性仍要看延迟、丢包与切换。',[
                    E('div',{'class':'kk-dji-signals'},[
                        E('div',{},[E('span',{},'RSRP · 参考信号功率'),E('strong',{id:'kk-dji-rsrp'},'—'),E('small',{},'优 ≥ −85 · 可用 ≥ −95 · 弱 ≥ −105 · 差 < −105 dBm')]),
                        E('div',{},[E('span',{},'RSRQ · 参考信号质量'),E('strong',{id:'kk-dji-rsrq'},'—'),E('small',{},'优 ≥ −10 · 可用 ≥ −15 · 弱 ≥ −20 · 差 < −20 dB')]),
                        E('div',{},[E('span',{},'SINR · 信号与干扰比'),E('strong',{id:'kk-dji-sinr'},'—'),E('small',{},'优 ≥ 20 · 可用 ≥ 10 · 弱 ≥ 3 · 差 < 3 dB')]),
                        E('div',{},[E('span',{},'RSSI · 总接收功率'),E('strong',{id:'kk-dji-rssi'},'—'),E('small',{},'强 ≥ −70 · 一般 ≥ −80 · 弱 ≥ −90 · 差 < −90 dBm')])
                    ]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-signal-time'},'尚未读取信号'),
                    E('p',{'class':'kk-dji-note'},'RSRP、RSRQ 和 SINR 优先判断；RSSI 包含干扰与噪声，不能单独代表网速。')
                ]),
                card('连接详情','有线出口优先时，DJI 可保持在线备用。',[
                    E('div',{'class':'kk-dji-rows'},[
                        row('运营商','kk-dji-operator'),row('网络制式','kk-dji-technology'),row('频段 / 信道','kk-dji-cell'),
                        row('SIM 锁状态','kk-dji-pin'),row('邻区','kk-dji-neighbors'),row('最强邻区 RSRP','kk-dji-neighbor-rsrp'),
                        row('蜂窝网卡','kk-dji-device'),row('蜂窝 IP','kk-dji-ip'),row('连接时长','kk-dji-uptime'),
                        row('接口接收','kk-dji-rx'),row('接口发送','kk-dji-tx')
                    ])
                ]),
                card('模块与维护','重连会短暂中断 DJI 蜂窝连接。',[
                    E('div',{'class':'kk-dji-rows'},[row('模块型号','kk-dji-model'),row('固件版本','kk-dji-firmware'),row('模块温度','kk-dji-temperature'),row('控制接口','kk-dji-control'),row('能力状态','kk-dji-ability')]),
                    E('div',{'class':'kk-dji-actions'},[this.reconnectButton]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-maintenance-note'},'设备操作会按模块实际能力开放。')
                ]),
                card('套餐与流量','运营商短信校正套餐口径；网卡计数单独累计。',[
                    E('div',{'class':'kk-dji-traffic-highlights'},[
                        E('div',{},[E('span',{},'套餐剩余 · 估算'),E('strong',{id:'kk-dji-balance'},'—'),E('small',{id:'kk-dji-balance-time'},'等待运营商回复')]),
                        E('div',{},[E('span',{},'本月设备收发'),E('strong',{id:'kk-dji-month'},'—'),E('small',{},'接收 + 发送')]),
                        E('div',{},[E('span',{},'今日设备收发'),E('strong',{id:'kk-dji-day'},'—'),E('small',{},'接收 + 发送')])
                    ]),
                    E('div',{'class':'kk-dji-rows'},[row('运营商最近报告已用','kk-dji-carrier-used'),row('运营商最近报告剩余','kk-dji-carrier-left'),row('设备累计接收 / 发送','kk-dji-local-total'),row('校正状态','kk-dji-traffic-state')]),
                    E('div',{'class':'kk-dji-traffic-controls'},[
                        E('label',{},['运营商',this.trafficOperator]),E('label',{},['查询号码',this.trafficRecipient]),E('label',{},['短信指令',this.trafficCommand]),
                        E('label',{'class':'kk-dji-check'},[this.trafficDaily,'每天校正']),E('label',{},['查询时间',this.trafficHour])
                    ]),
                    E('div',{'class':'kk-dji-actions'},[this.trafficSaveButton,this.trafficQueryButton]),
                    E('p',{'class':'kk-dji-note'},'默认电信 10001 / 108；移动与联通指令可能因省份和套餐不同，请先核对本卡。短信可能产生费用。运营商已用/剩余是最近回复；估算值再叠加本设备后续流量，不包含其他设备耗用。')
                ],'kk-dji-traffic-card'),
                card('短信中心','原件优先存在 SIM；树莓派连接时加密归档到 SD 卡。',[
                    E('div',{'class':'kk-dji-actions'},[this.smsListButton,E('span',{id:'kk-dji-sms-count','class':'kk-muted'},'尚未读取')]),
                    E('p',{'class':'kk-dji-note'},'打开页面即读取目录，之后定时更新；长短信合并显示。读取详情可能标为已读，不会自动删除。'),
                    E('div',{'class':'kk-dji-sms-workspace'},[
                        E('div',{'class':'kk-dji-sms-inbox'},[this.smsSearch,this.smsListArea]),
                        E('div',{'class':'kk-dji-sms-detail'},[
                            E('div',{'class':'kk-dji-sms-detail-head'},[E('h3',{},'短信详情'),E('div',{'class':'kk-dji-actions'},[this.smsReplyButton,this.smsClearButton,this.smsDeleteButton])]),
                            this.smsDetailMeta,this.smsDetailBody,this.smsForm
                        ])
                    ]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-sms-note'},'等待检测短信能力。')
                ],'kk-dji-sms-card'),
                card('网页电话','本机已完成一次双向声音短测；长期和移动中的通话稳定性仍需观察。',[
                    E('div',{'class':'kk-dji-call-state'},[E('strong',{id:'kk-dji-call-title'},'尚未验证双向音频'),E('span',{id:'kk-dji-call-subtitle'},'网页拨号暂不开放')]),
                    E('div',{'class':'kk-dji-phone-controls'},[this.callNumber,this.callDialButton,this.callAnswerButton,this.callHangupButton,this.voiceProbeButton,this.httpsPhoneButton]),this.voiceStatus,
                    E('p',{'class':'kk-dji-note'},'请从 HTTPS 管理页使用，并允许浏览器访问麦克风。一次 15–30 秒双向通话已通过；长期稳定性尚未验收，请勿用于紧急联络。')
                ],'kk-dji-phone-card'),
                card('定位','定位功能取决于模块固件和天线，首次锁定可能需要一段时间。',[
                    E('div',{'class':'kk-dji-rows'},[row('GPS 状态','kk-dji-gps-state'),row('定位结果','kk-dji-gps-fix'),row('经纬度','kk-dji-gps-coords'),row('速度','kk-dji-gps-speed'),row('更新时间','kk-dji-gps-time')]),
                    E('div',{'class':'kk-dji-actions'},[this.gpsStartButton,this.gpsStopButton,this.gpsProbeButton]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-gps-note'},'尚未检测定位能力。')
                ]),
                card('VoHive 能力对照','按这只模块和车载路由用途核对，不把未经验证的功能伪装成可用按钮。',[
                    E('div',{'class':'kk-dji-rows'},[
                        row('设备、网络与信号','kk-dji-parity-device'),row('短信目录与详情','kk-dji-parity-sms'),
                        row('网络重连','kk-dji-parity-reconnect'),row('飞书通知','kk-dji-parity-notify'),
                        row('eSIM / 多卡','kk-dji-parity-esim'),row('代理池 / VoWiFi','kk-dji-parity-proxy'),row('SIM 电话 / 音频','kk-dji-parity-voice')
                    ]),
                    E('p',{'class':'kk-dji-note'},'VoHive 是运行在 Linux 主机上的软件；此页运行在树莓派，不需要电脑常驻。')
                ]),
                card('使用说明','当前控制的是插在树莓派上的 DJI 模块。',[
                    E('p',{'class':'kk-dji-note'},'公网出口、VPN 与分流状态请看网络面板。短信和位置仅在当前管理会话中显示，不保存在浏览器。'),
                    E('p',{'class':'kk-dji-note'},'套餐用量请以运营商查询结果为准；接口字节计数不等于运营商计费量。')
                ])
            ])
        ]);
        this.paint(data);
        poll.add(function(){return self.refresh(false);},5);
        poll.add(function(){return self.readSmsList(true);},30);
        poll.add(function(){return self.readCallState();},3);
        poll.add(function(){return self.readGps(false);},30);
        Promise.resolve().then(function(){return self.readSmsList(true);});
        Promise.resolve().then(function(){return self.readCallState();});
        Promise.resolve().then(function(){return self.checkVoice();});
        Promise.resolve().then(function(){return self.readGps(false);});
        return this.root;
    },
    el:function(id){return this.root.querySelector('#'+id);},
    set:function(id,value){this.el(id).textContent=shown(value);},
    notify:function(message,error){this.notice.hidden=false;this.notice.className='kk-notice'+(error?' error':'');this.notice.textContent=message;},
    refresh:function(loud){
        var self=this,request=loud && this.capabilities && this.capabilities.refresh===true ? djiAction('refresh') : Promise.resolve({ok:true});
        if(loud)this.refreshButton.disabled=true;
        return request.then(function(reply){if(reply.ok===false)throw Error(reply.error || '刷新失败');return self.load();}).then(function(data){self.paint(data);if(loud)self.notify(self.capabilities.refresh===true?'已请求模块重新采样，状态会在后台更新。':'已读取最新状态。');}).catch(function(err){self.el('kk-dji-update').textContent='读取失败';if(loud)self.notify(err.message || '暂时无法读取路由器状态，请检查管理连接。',true);}).finally(function(){self.refreshButton.disabled=false;});
    },
    paint:function(data){
        var base=data.network || {}, extra=data.device || {}, modem=base.modem && base.modem.transport==='QMI' ? base.modem : {},
            identity=extra.identity || {},sim=extra.sim || {},radio=extra.radio || {},session=extra.session || {},gps=extra.gps || {},
            caps=extra.capabilities || {}, stamp=first(extra.updated_at,extra.timestamp,modem.timestamp), stale=stamp==null || Date.now()/1000-stamp>90,
            available=extra.available !== false && (extra.ok === true || modem.online === true),
            simState=first(sim.state,modem.sim_state), registration=first(radio.registration,modem.registration),
            connected=first(session.connected,modem.connected), active=(base.uplink || {}).active || '',
            rsrp=first(radio.rsrp,modem.rsrp),rsrq=first(radio.rsrq,modem.rsrq),sinr=radio.sinr,
            rssi=first(radio.rssi,modem.rssi);
        this.device=extra;this.capabilities=caps;this.lastNetwork=base;
        if(data.traffic)this.lastTraffic=data.traffic;
        this.paintTraffic(data.traffic || this.lastTraffic);
        this.el('kk-dji-update').textContent=stale?'状态已过期':'更新于 '+ago(stamp);
        this.summary.textContent=!available?'模块未连通':stale?'等候新状态':connected===true?'DJI 蜂窝已连接':'DJI 蜂窝未连接';
        this.summary.dataset.tone=!available||stale?'warning':connected?'good':'neutral';
        this.set('kk-dji-description',!available?shown(extra.reason,'尚未检测到 DJI 控制接口。'):stale?'最近数据已过期，等待后台重新采样。':active==='ethernet'?'有线 WAN 正在使用，DJI 作为蜂窝备用线路。':connected?'蜂窝数据连接可用，实际网络访问仍以网络检查为准。':'模块已识别，正在等待数据会话。');
        this.set('kk-dji-sim',simLabel(simState));
        this.set('kk-dji-register',registration!=null?registerLabel(registration):!available?'未检测':radio.registered===true?'已注册':radio.registered===false?'未注册':'未检测');
        this.set('kk-dji-session',connected===true?'已连接':connected===false?'未连接':'未检测');
        this.set('kk-dji-uplink',active==='ethernet'?'有线 WAN':active==='cellular'?'DJI 4G':active==='none'?'无可用出口':'未检测');
        this.set('kk-dji-rsrp',metric(rsrp,' dBm'));
        this.set('kk-dji-rsrq',metric(rsrq,' dB'));
        this.set('kk-dji-sinr',metric(sinr,' dB',1));
        this.set('kk-dji-rssi',metric(rssi,' dBm'));
        [['rsrp',rsrp,-85,-95,-105],['rsrq',rsrq,-10,-15,-20],['sinr',sinr,20,10,3],['rssi',rssi,-70,-80,-90]].forEach(function(item){
            this.el('kk-dji-'+item[0]).dataset.tone=stale?'unknown':signalTone(item[1],item[2],item[3],item[4]);
        },this);
        this.set('kk-dji-signal-time',stale?'信号数据已过期 · 最近采样 '+clock(stamp):'最近采样 '+clock(stamp));
        var operator=first(radio.operator,modem.operator);
        this.set('kk-dji-operator',({'CT':'中国电信','CMCC':'中国移动','CU':'中国联通'})[operator] || operator);
        this.set('kk-dji-technology',first(radio.technology,radio.network,modem.network));
        this.set('kk-dji-cell',[first(radio.band,modem.band),radio.channel].filter(function(v){return v!=null&&v!=='';}).join(' · ') || null);
        this.set('kk-dji-pin',sim.pin_state==='ready'?'已解锁':sim.pin_state==='pin_required'?'需要 PIN':sim.pin_state==='puk_required'?'需要 PUK':null);
        var neighbours=radio.neighbours || {}, intra=neighbours.intra_count, inter=neighbours.inter_count;
        this.set('kk-dji-neighbors',intra==null&&inter==null?null:(Number(intra || 0)+Number(inter || 0))+' 个（同频 '+Number(intra || 0)+' / 异频 '+Number(inter || 0)+'）');
        this.set('kk-dji-neighbor-rsrp',metric(neighbours.best_rsrp_dbm,' dBm'));
        this.set('kk-dji-device',first(session.device,active==='cellular'?(base.wan || {}).device:null,modem.device));
        this.set('kk-dji-ip',first(session.ip,active==='cellular'?(base.wan || {}).ip:null));
        this.set('kk-dji-uptime',duration(first(session.uptime,modem.connection_uptime)));
        this.set('kk-dji-rx',size(first(session.rx_bytes,modem.rx)));
        this.set('kk-dji-tx',size(first(session.tx_bytes,modem.tx)));
        this.set('kk-dji-model',first(identity.model,modem.model));
        this.set('kk-dji-firmware',first(identity.firmware,modem.firmware));
        this.set('kk-dji-temperature',metric(extra.temperature_c,' °C',1));
        this.set('kk-dji-control',first(identity.transport,modem.transport));
        this.set('kk-dji-ability',extra.ok===true?'控制服务可用':modem.online?'只读状态可用':'暂不可用');
        this.reconnectButton.disabled=!(caps.reconnect===true) || stale || this.operating===true;
        this.el('kk-dji-maintenance-note').textContent=caps.reconnect===true?'重连只作用于 DJI 数据会话；操作中蜂窝网络和 VPN 可能暂时中断。':'当前未开放模块重连控制。';
        var smsReadAvailable=caps.sms_read===true || caps.sms_list===true, smsSendAvailable=caps.sms_send===true;
        this.smsListButton.disabled=!smsReadAvailable || this.smsLoading===true;
        this.smsForm.hidden=!smsSendAvailable;
        var sms=extra.sms || {}, used=first(sms.used,sms.count), capacity=first(sms.capacity,sms.total),
            smsPlace=sms.storage==='SM'?'SIM':sms.storage==='ME'?'模块内存':'短信仓';
        if(used!=null && capacity!=null){
            this.el('kk-dji-sms-count').textContent=smsPlace+' '+used+' / '+capacity+(Number(used)>=Number(capacity)?' · 已满':'');
            this.el('kk-dji-sms-count').className=Number(used)>=Number(capacity)?'kk-dji-full':'kk-muted';
        }
        var forward=extra.sms_forward || {};
        this.el('kk-dji-sms-note').textContent=!smsReadAvailable&&!smsSendAvailable?'当前固件或控制服务未开放短信功能。':
            (used!=null&&capacity!=null&&Number(used)>=Number(capacity)?smsPlace+'已满，新短信可能无法接收。请先备份并清理旧短信。 ':smsPlace+'保存原件；树莓派在运行时把完整短信加密归档到 SD 卡。 ')+
            (forward.error?'归档/推送提醒：'+forward.error+'。':forward.enabled?'新短信正文转发飞书已开启'+(forward.pending?'，待重试 '+forward.pending+' 条':'')+'。':'新短信飞书转发已关闭，可在“飞书推送”中开启。');
        var liveGps=this.liveGps || {},gpsSupported=gps.supported===true, gpsControl=caps.gps===true,
            gpsEnabled=liveGps.ok===true?liveGps.enabled===true:gps.enabled===true,
            fix=liveGps.ok===true && liveGps.fix===true;
        this.set('kk-dji-gps-state',!gpsSupported?'暂不可用':gpsEnabled?'已启动':'已关闭');
        this.set('kk-dji-gps-fix',!gpsSupported?'未检测':fix?'已定位':gpsEnabled?'等待卫星定位':'未启动');
        this.set('kk-dji-gps-coords',fix?metric(liveGps.lat,'',5)+', '+metric(liveGps.lon,'',5):null);
        this.set('kk-dji-gps-speed',fix?metric(liveGps.speed_kmh,' km/h',1):null);
        this.set('kk-dji-gps-time',liveGps.ok===true?clock(liveGps.updated_at):null);
        this.gpsStartButton.hidden=!gpsControl || gpsEnabled;
        this.gpsStopButton.hidden=!gpsControl || !gpsEnabled;
        this.gpsStartButton.disabled=this.gpsStopButton.disabled=!gpsControl || this.operating===true;
        this.gpsProbeButton.disabled=!gpsControl || this.gpsLoading===true;
        this.el('kk-dji-gps-note').textContent=!gpsSupported?'暂未检测到可用的定位命令。':!gpsControl?'定位命令可响应，但控制接口暂不可用。':fix?'卫星 '+shown(liveGps.satellites)+' 颗 · HDOP '+metric(liveGps.hdop,'',1)+'；当前页面显示，不自动保存轨迹。':gpsEnabled?'正在等待卫星定位；需要可用的 GNSS 天线和较开阔的天空，网络信号强不代表卫星信号好。':'可手动启动定位；开启不会重启蜂窝网络。';
        this.set('kk-dji-parity-device',available?'已接入':'模块未连通');
        this.set('kk-dji-parity-sms',smsReadAvailable?'已接入 · 点击单条读取':'当前不可用');
        this.set('kk-dji-parity-reconnect',caps.reconnect===true?'已接入':'当前不可用');
        this.set('kk-dji-parity-notify',forward.enabled?'系统告警与新短信转发已接入':'系统告警已接入 · 短信转发未开启');
        this.set('kk-dji-parity-esim','当前未识别 eSIM 能力');
        this.set('kk-dji-parity-proxy','车载场景未启用');
        this.set('kk-dji-parity-voice',this.voiceResult?.ready===true?'短时双向已通 · 长期待验收':this.voiceResult?'控制与音频未齐备':'待检测');
    },
    trafficPreset:function(){
        var preset={CT:['10001','108'],CMCC:['10086','CXYL'],CU:['10010','CXLLJ']}[this.trafficOperator.value];
        if(preset){this.trafficRecipient.value=preset[0];this.trafficCommand.value=preset[1];}
    },
    paintTraffic:function(reply){
        var t=reply && reply.ok===true ? reply.data || {} : {},c=t.config || {};
        if(!this.trafficLoaded){
            this.trafficOperator.value=c.operator || 'CT';this.trafficRecipient.value=c.recipient || '10001';
            this.trafficCommand.value=c.command || '108';this.trafficDaily.checked=c.daily===true;
            this.trafficHour.value=String(c.hour==null?9:c.hour);this.trafficLoaded=true;
        }
        var a=t.anchor || null,day=t.day || {},month=t.month || {},total=t.total || {};
        this.set('kk-dji-balance',a?size(t.estimated_remaining):null);
        this.set('kk-dji-balance-time',a?'校正于 '+a.time:'尚无可识别的运营商回复');
        this.set('kk-dji-day',t.timestamp?size(Number(day.rx || 0)+Number(day.tx || 0)):null);
        this.set('kk-dji-month',t.timestamp?size(Number(month.rx || 0)+Number(month.tx || 0)):null);
        this.set('kk-dji-carrier-used',a?size(a.used_bytes):null);
        this.set('kk-dji-carrier-left',a?size(a.remaining_bytes):null);
        this.set('kk-dji-local-total',t.timestamp?size(total.rx)+' / '+size(total.tx):null);
        this.set('kk-dji-traffic-state',t.parse_error || (t.pending?'等待运营商回复':a?'已按 '+a.package+' 校正':'尚未校正'));
        this.trafficQueryButton.disabled=!this.capabilities || this.capabilities.sms_send!==true;
    },
    saveTraffic:function(){
        var self=this,operator=this.trafficOperator.value,recipient=this.trafficRecipient.value.trim(),command=this.trafficCommand.value.trim();
        if(!/^\d{3,6}$/.test(recipient)||!/^[A-Za-z0-9]{1,20}$/.test(command)){this.notify('请检查查询号码和指令。',true);return;}
        this.trafficSaveButton.disabled=true;
        return trafficSave(operator,recipient,command,this.trafficDaily.checked,Number(this.trafficHour.value))
            .then(function(r){if(!r||r.ok!==true)throw Error(r && r.error || '保存失败');self.notify('流量查询设置已保存。');return self.refresh(false);})
            .catch(function(e){self.notify(e.message || '保存失败',true);})
            .finally(function(){self.trafficSaveButton.disabled=false;});
    },
    queryTraffic:function(){
        var self=this;
        if(!window.confirm('向当前保存的运营商号码发送一次流量查询短信？回复到达后自动校正。'))return;
        this.trafficQueryButton.disabled=true;
        return trafficQuery().then(function(r){
            if(!r || r.ok!==true)throw Error(r && r.error || '短信查询失败');
            self.notify('查询短信已提交；收到可识别的回复后会自动校正。');return self.refresh(false);
        }).catch(function(e){self.notify(e.message || '查询失败',true);})
            .finally(function(){self.trafficQueryButton.disabled=false;});
    },
    perform:function(kind,message){
        var self=this;
        if((kind==='reconnect' && this.capabilities.reconnect!==true) || (kind==='gps_start' && this.capabilities.gps_start!==true) || (kind==='gps_stop' && this.capabilities.gps_stop!==true))return;
        if(this.operating)return;
        this.operating=true;this.reconnectButton.disabled=this.gpsStartButton.disabled=this.gpsStopButton.disabled=true;
        return djiAction(kind).then(function(reply){if(reply.ok===false)throw Error(reply.error || '操作失败');self.notify(message);return self.refresh(false);}).catch(function(err){self.notify(err.message || '模块操作失败',true);}).finally(function(){self.operating=false;self.paint({network:self.lastNetwork || {},device:self.device || {},traffic:self.lastTraffic});});
    },
    reconnect:function(){
        if(this.capabilities.reconnect!==true)return;
        if(!window.confirm('确认重连 DJI 蜂窝数据网络？使用 DJI 上网时会短暂断开。'))return;
        this.perform('reconnect','已请求重连 DJI，蜂窝连接正在恢复。');
    },
    performGps:function(kind){
        var self=this;
        if(!this.capabilities || this.capabilities.gps!==true || this.operating)return;
        if(kind==='gps_start' && !window.confirm('启动卫星定位？这可能增加模块功耗；没有 GNSS 天线时可能一直无法获得位置。'))return;
        this.operating=true;
        this.gpsStartButton.disabled=this.gpsStopButton.disabled=true;
        return djiAction(kind).then(function(reply){
            if(!reply || reply.ok!==true)throw Error(reply && reply.error || '定位操作失败');
            self.liveGps=reply;
            self.notify(kind==='gps_start'?'定位已启动；获得卫星位置前不会显示坐标。':'定位已停止。');
            self.paint({network:self.lastNetwork || {},device:self.device || {},traffic:self.lastTraffic});
        }).catch(function(err){self.notify(err.message || '定位操作失败',true);})
            .finally(function(){self.operating=false;self.gpsStartButton.disabled=self.gpsStopButton.disabled=false;});
    },
    readGps:function(loud){
        var self=this;
        if(!this.capabilities || this.capabilities.gps!==true || this.gpsLoading)return;
        this.gpsLoading=true;this.gpsProbeButton.disabled=true;
        return gpsProbe().then(function(reply){
            if(!reply || reply.ok!==true)throw Error(reply && reply.error || '定位状态读取失败');
            self.liveGps=reply;
            self.paint({network:self.lastNetwork || {},device:self.device || {},traffic:self.lastTraffic});
            if(loud)self.notify(reply.fix?'已读取卫星位置与速度。':reply.enabled?'定位已开启，尚未获得卫星位置。':'定位处于关闭状态。');
        }).catch(function(err){if(loud)self.notify(err.message || '定位状态读取失败',true);})
            .finally(function(){self.gpsLoading=false;self.gpsProbeButton.disabled=false;});
    },
    readCallState:function(){
        var self=this;
        if(!this.capabilities || this.capabilities.sms_read!==true || this.callLoading)return;
        this.callLoading=true;
        return callStatus().then(function(reply){
            if(!reply || reply.ok!==true)return;
            self.currentCall=reply;
            var active=reply.count>0;
            self.set('kk-dji-call-title',active?reply.state:'电话线路空闲');
            self.set('kk-dji-call-subtitle',active?(reply.direction==='incoming'?'SIM 收到来电':'SIM 电话正在处理'):'自动检查于 '+ago(reply.timestamp));
            self.updatePhoneButtons();
            if(active && reply.direction==='outgoing' && reply.state==='通话中' && reply.audio_ready===true && !self.audioSocket && !self.voiceBusy){
                self.openPhoneAudio().then(function(){self.notify('电话已接通，浏览器音频已连接。');})
                    .catch(function(error){self.notify(error.message || '通话音频连接失败',true);});
            }
            if(!active && self.audioSocket && Date.now()-(self.callStartAt || 0)>10000)self.closePhoneAudio();
        }).catch(function(){}).finally(function(){self.callLoading=false;});
    },
    checkVoice:function(){
        var self=this;this.voiceProbeButton.disabled=true;this.voiceStatus.textContent='正在只读检测通话控制与 USB 音频…';
        return voiceProbe().then(function(result){
            if(!result || result.ok!==true)throw Error(result && result.error || '检测失败');
            self.voiceResult=result;
            self.voiceReady=result.ready===true;
            self.set('kk-dji-call-title',result.active_calls>0?result.call_state:result.ready?'电话硬件就绪':'通话条件待验证');
            self.set('kk-dji-call-subtitle',result.ready?'接通后自动启动音频路由':'请检查模块音频资源');
            self.voiceStatus.textContent='语音 USB 位：'+(result.usb_voice_enabled===true?'开':result.usb_voice_enabled===false?'关':'未知')+
                ' · IMS 配置：'+(result.ims_setting==null?'未知':result.ims_setting)+
                ' · USB 声卡：'+(result.audio_usb_present?'已枚举':'未枚举')+
                ' · 通话查询：'+(result.call_query_accepted?'有响应':'无响应')+
                (result.route_ready?' · 正在传输通话音频。':result.ready?' · 接通后启动音频路由。':' · 模块音频资源未就绪。');
            self.set('kk-dji-parity-voice',result.ready===true?'短时双向已通；长期稳定性待验收':'通话与音频条件不足');
            self.updatePhoneButtons();
        }).catch(function(error){self.voiceStatus.textContent='电话能力检测失败：'+(error.message || '未知错误');})
            .finally(function(){self.voiceProbeButton.disabled=false;});
    },
    updatePhoneButtons:function(){
        var state=this.currentCall || {}, usable=this.voiceReady && window.isSecureContext===true && !this.voiceBusy;
        this.callDialButton.disabled=!usable || state.count>0;
        this.callAnswerButton.disabled=!usable || state.direction!=='incoming' || state.count<1 ||
            (state.state!=='来电振铃' && state.state!=='来电等待');
        this.callHangupButton.disabled=!this.voiceReady || state.count<1;
    },
    openPhoneAudio:function(){
        var self=this;
        if(this.audioSocket && this.audioSocket.readyState===WebSocket.OPEN)return Promise.resolve();
        if(!window.isSecureContext || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.AudioWorkletNode)
            return Promise.reject(Error('浏览器需要可信 HTTPS、麦克风权限和 AudioWorklet。'));
        return navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}})
            .then(function(stream){
                self.audioStream=stream;
                self.audioContext=new (window.AudioContext || window.webkitAudioContext)({latencyHint:'interactive'});
                return self.audioContext.audioWorklet.addModule(L.resource('view/kkcar/voice-worklet.js')).then(function(){
                    self.audioNode=new AudioWorkletNode(self.audioContext,'kkcar-voice');
                    self.audioSource=self.audioContext.createMediaStreamSource(stream);
                    self.audioSource.connect(self.audioNode);self.audioNode.connect(self.audioContext.destination);
                    return self.audioContext.resume();
                });
            }).then(function(){return voiceTicket();}).then(function(ticket){
                if(!ticket || ticket.ok!==true)throw Error(ticket && ticket.error || '无法创建通话音频会话');
                var local=window.location.hostname==='localhost' || window.location.hostname==='127.0.0.1';
                var address=local?'localhost:18887':window.location.hostname+':8443';
                return new Promise(function(resolve,reject){
                    var ws=new WebSocket((local?'ws':'wss')+'://'+address+'/audio?ticket='+encodeURIComponent(ticket.token));
                    var opened=false,timer=setTimeout(function(){if(!opened){ws.close();reject(Error('语音网关连接超时'));}},8000);
                    ws.binaryType='arraybuffer';self.audioSocket=ws;
                    ws.onopen=function(){opened=true;clearTimeout(timer);resolve();};
                    ws.onerror=function(){if(!opened){clearTimeout(timer);reject(Error('无法连接语音网关；请检查 HTTPS 证书和服务状态'));}};
                    ws.onclose=function(){if(opened && self.audioSocket===ws){self.closePhoneAudio();self.notify('通话音频已断开，请检查模块语音路由。',true);}};
                    ws.onmessage=function(event){if(event.data instanceof ArrayBuffer && self.audioNode)self.audioNode.port.postMessage({down:event.data},[event.data]);};
                    self.audioNode.port.onmessage=function(event){if(ws.readyState===WebSocket.OPEN && ws.bufferedAmount<32000)ws.send(event.data);};
                });
            }).catch(function(error){self.closePhoneAudio();throw error;});
    },
    closePhoneAudio:function(){
        var socket=this.audioSocket;this.audioSocket=null;
        if(socket && socket.readyState<=WebSocket.OPEN)socket.close();
        if(this.audioStream)this.audioStream.getTracks().forEach(function(track){track.stop();});
        this.audioStream=null;
        if(this.audioContext)this.audioContext.close().catch(function(){});
        this.audioContext=null;this.audioNode=null;this.audioSource=null;
    },
    phoneDial:function(){
        var self=this,number=(this.callNumber.value || '').trim();
        if(!/^\+?[0-9]{3,15}$/.test(number)){this.notify('请输入有效电话号码。',true);return;}
        if(this.voiceBusy)return;
        this.voiceBusy=true;this.updatePhoneButtons();
        return callDial(number).then(function(reply){
            if(!reply || reply.ok!==true)throw Error(reply && reply.error || '拨号失败');
            self.callStartAt=Date.now();self.notify('已交给 SIM 拨号；对方接通后自动连接音频。');return self.readCallState();
        }).catch(function(error){self.closePhoneAudio();self.notify(error.message || '拨号失败',true);})
            .finally(function(){self.voiceBusy=false;self.updatePhoneButtons();});
    },
    phoneAnswer:function(){
        var self=this;if(this.voiceBusy)return;
        this.voiceBusy=true;this.updatePhoneButtons();
        return callAnswer().then(function(reply){
            if(!reply || reply.ok!==true)throw Error(reply && reply.error || '接听失败');
            self.callStartAt=Date.now();return self.openPhoneAudio();
        }).then(function(){
            self.notify('模块已接听，网页音频已连接；请确认通话是否保持、双方能否听见。');return self.readCallState();
        }).catch(function(error){self.closePhoneAudio();self.notify(error.message || '接听失败',true);})
            .finally(function(){self.voiceBusy=false;self.updatePhoneButtons();});
    },
    phoneHangup:function(){
        var self=this;
        return callHangup().then(function(reply){if(!reply || reply.ok!==true)throw Error(reply && reply.error || '挂断失败');self.notify('通话已结束。');})
            .catch(function(error){self.notify(error.message || '挂断失败',true);})
            .finally(function(){self.closePhoneAudio();self.readCallState();});
    },
    readSmsList:function(background){
        var self=this;
        if(!(this.capabilities.sms_read===true || this.capabilities.sms_list===true))return;
        if(this.smsLoading)return;
        this.smsLoading=true;this.smsListButton.disabled=true;
        if(!background || !this.smsItems.length)this.smsListArea.textContent='正在读取短信目录…';
        return smsList().then(function(reply){
            if(!reply || reply.ok!==true || !Array.isArray(reply.messages))throw Error((reply && reply.error) || '模块未返回短信目录');
            var messages=Array.isArray(reply.groups)?reply.groups:reply.messages;
            var selected=self.smsItems.find(function(x){return Number(x.index)===self.selectedSmsIndex;});
            var still=selected && messages.some(function(x){return Number(x.index)===self.selectedSmsIndex && x.from===selected.from && x.time===selected.time;});
            if(!still)self.clearSmsDetail();
            self.smsItems=messages.slice().sort(function(a,b){
                var unreadA=a.status==='未读'?1:0,unreadB=b.status==='未读'?1:0;
                return unreadB-unreadA || String(b.time || '').localeCompare(String(a.time || ''));
            });
            var unread=self.smsItems.filter(function(x){return x.status==='未读';}).length;
            self.el('kk-dji-sms-count').textContent=messages.length+' 条短信'+(unread?' · '+unread+' 条未读':'')+' / '+reply.count+' 个存储槽';
            self.renderSmsItems();
        }).catch(function(err){if(!background || !self.smsItems.length)self.smsListArea.textContent='短信目录读取失败：'+(err.message || '未知错误');}).finally(function(){self.smsLoading=false;self.smsListButton.disabled=false;});
    },
    renderSmsItems:function(){
        var self=this,query=(this.smsSearch.value || '').trim().toLowerCase();
        var messages=this.smsItems.filter(function(item){
            return !query || [item.from,item.number,item.time,item.status].some(function(v){return String(v || '').toLowerCase().indexOf(query)>=0;});
        });
        if(!messages.length){this.smsListArea.textContent=this.smsItems.length?'没有匹配的短信。':'模块存储中没有短信。';return;}
        this.smsListArea.replaceChildren.apply(this.smsListArea,messages.map(function(item){
            var index=Number(item.index),safe=Number.isInteger(index)&&index>=0&&index<=255;
            var select=E('button',{type:'button','class':'kk-dji-sms-item'+(index===self.selectedSmsIndex?' selected':''),
                click:function(){self.readSms(index);}},[
                E('span',{'class':'kk-dji-sms-item-top'},[E('strong',{},shown(item.from || item.number,'未知号码')),E('small',{},shown(item.status,'状态未知'))]),
                E('span',{'class':'kk-dji-sms-item-bottom'},[E('span',{},shown(item.time,'时间未知')),E('span',{},item.concat?'长短信 '+item.parts.filter(function(n){return Number.isInteger(n);}).length+'/'+item.concat.total+(item.complete?' · 查看合并正文 →':' · 缺少片段'):'查看正文 →')])
            ]);
            select.disabled=!safe;
            return select;
        }));
    },
    clearSmsDetail:function(){
        this.smsRequestId=(this.smsRequestId || 0)+1;
        this.selectedSmsIndex=null;this.smsReading=false;
        this.smsDetailMeta.textContent='选择左侧短信查看正文';
        this.smsDetailBody.textContent='正文只在你点击短信后读取，不保存在浏览器。';
        this.smsDeleteButton.disabled=true;
        this.smsReplyButton.disabled=true;
        this.smsListArea.querySelectorAll('.kk-dji-sms-item.selected').forEach(function(el){el.classList.remove('selected');});
    },
    readSms:function(index){
        var self=this,item=this.smsItems.find(function(message){return Number(message.index)===index;});
        if(!item || this.smsReading)return;
        this.clearSmsDetail();this.selectedSmsIndex=index;this.smsReading=true;
        var requestId=this.smsRequestId;
        this.smsDetailMeta.textContent=shown(item.from || item.number,'未知号码')+' · '+shown(item.time,'时间未知')+' · '+shown(item.status,'状态未知');
        var parts=Array.isArray(item.parts)?item.parts:[index];
        this.smsDetailBody.textContent='正在读取 '+parts.filter(function(n){return Number.isInteger(n);}).length+' 个短信片段…';
        this.renderSmsItems();
        var joined=Promise.resolve([]);
        parts.forEach(function(part,position){
            joined=joined.then(function(result){
                if(!Number.isInteger(part))return result;
                return smsRead(String(part)).then(function(reply){
                    if(!reply || reply.ok!==true || !reply.message)throw Error((reply && reply.error) || '模块未返回短信详情');
                    var segment=reply.message;
                    if(segment.unsupported || typeof segment.text!=='string')throw Error('这条短信的编码暂不支持显示');
                    if(segment.from!==item.from || (item.concat && (!segment.concat || segment.concat.ref!==item.concat.ref || segment.concat.bits!==item.concat.bits || segment.concat.total!==item.concat.total || segment.concat.part!==position+1)))throw Error('短信片段已变化，请重新读取列表');
                    result[position]=segment.text;
                    return result;
                });
            });
        });
        return joined.then(function(result){
            if(self.smsRequestId!==requestId || self.selectedSmsIndex!==index)return;
            var body='';
            for(var i=0;i<parts.length;i++)body+=result[i]==null?'[缺少第 '+(i+1)+' 段]':result[i];
            self.smsDetailBody.textContent=(item.complete?'':'片段尚未收齐，以下内容不完整：\n')+(body || '这是一条空短信。');
            self.smsDeleteButton.disabled=self.capabilities.sms_delete!==true;
            self.smsReplyButton.disabled=!/^\+?[0-9]{3,15}$/.test(item.from || '');
        }).catch(function(err){if(self.smsRequestId===requestId && self.selectedSmsIndex===index)self.smsDetailBody.textContent='读取失败：'+(err.message || '未知错误');})
            .finally(function(){if(self.smsRequestId===requestId)self.smsReading=false;});
    },
    replySelectedSms:function(){
        var item=this.smsItems.find(function(message){return Number(message.index)===this.selectedSmsIndex;},this);
        if(!item || !/^\+?[0-9]{3,15}$/.test(item.from || ''))return;
        this.to.value=item.from;
        this.text.focus();
        this.notify('已填入收件号码；输入内容后再确认发送。');
    },
    deleteSelectedSms:function(){
        var self=this;
        if(this.capabilities.sms_delete!==true)return;
        var index=this.selectedSmsIndex;
        if(!Number.isInteger(index)||index<0||index>255)return;
        var item=this.smsItems.find(function(message){return Number(message.index)===index;});
        var parts=item && Array.isArray(item.parts)?item.parts.filter(function(n){return Number.isInteger(n);}):[index];
        if(!window.confirm('确认永久删除这条短信的 '+parts.length+' 个片段？删除后无法恢复。'))return;
        this.smsDeleteButton.disabled=true;
        var removed=0,work=Promise.resolve();
        parts.sort(function(a,b){return b-a;}).forEach(function(part){work=work.then(function(){return smsDelete(String(part)).then(function(reply){if(!reply || reply.ok!==true)throw Error((reply && reply.error) || '模块未确认删除');removed++;});});});
        return work.then(function(){
            self.clearSmsDetail();
            self.notify('短信已从模块删除。');
            return self.readSmsList().then(function(){return self.refresh(false);});
        }).catch(function(err){self.notify('已删除 '+removed+'/'+parts.length+' 个片段；'+(err.message || '请重新读取列表'),true);self.smsDeleteButton.disabled=false;self.readSmsList();});
    },
    sendSms:function(){
        var self=this,to=this.to.value.trim(),message=this.text.value;
        if(this.capabilities.sms_send!==true)return;
        if(!/^\+?[0-9]{3,15}$/.test(to)){this.notify('请填写有效的接收号码。',true);return;}
        if(!message.trim() || message.length>70 || /[\uD800-\uDFFF]/.test(message)){this.notify('短信内容应为 1–70 个普通字符，不支持 emoji。',true);return;}
        if(!window.confirm('确认通过 DJI 模块向 '+to+' 发送短信？'))return;
        var submit=this.smsForm.querySelector('button[type=submit]');submit.disabled=true;
        return smsSend(to,message).then(function(reply){if(reply.ok===false)throw Error(reply.error || '发送失败');self.text.value='';self.notify('短信已提交给模块，最终送达状态以运营商回执为准。');}).catch(function(err){self.notify(err.message || '短信发送失败',true);}).finally(function(){submit.disabled=false;});
    }
});
