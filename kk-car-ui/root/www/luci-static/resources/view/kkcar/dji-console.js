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

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return Promise.all([getNetwork(),getDji().catch(function(){return null;}),trafficStatus().catch(function(){return null;})]).then(function(results){return {network:results[0],device:results[1],traffic:results[2]};});},
    render:function(data){
        var self=this;
        document.title='KK-Car · DJI 4G';
        ['overview','dji-console'].forEach(function(name){var id='kk-css-'+name;if(!document.getElementById(id))document.head.appendChild(E('link',{id:id,rel:'stylesheet',href:L.resource('view/kkcar/'+name+'.css')}));});
        this.notice=E('div',{'class':'kk-notice',role:'status','aria-live':'polite',hidden:true});
        this.summary=E('strong',{id:'kk-dji-summary'},'读取中');
        this.refreshButton=button('刷新状态',function(){self.refresh(true);});
        this.reconnectButton=button('重连 DJI 数据网络',function(){self.reconnect();},'primary');
        this.smsListButton=button('刷新短信',function(){self.readSmsList();});
        this.voiceProbeButton=button('检测电话能力',function(){self.checkVoice();});
        this.voiceStatus=E('p',{'class':'kk-dji-note','aria-live':'polite'},'尚未检测电话接口与音频。检测只读，不会拨号或重启模块。');
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
        this.smsDeleteButton.disabled=true;
        this.gpsStartButton=button('启动定位',function(){self.perform('gps_start','已请求启动定位，稍后查看定位状态。');});
        this.gpsStopButton=button('停止定位',function(){self.perform('gps_stop','已请求停止定位。');});
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
                card('无线信号','LTE 信号来自模块实时采样；无读数时不推断好坏。',[
                    E('div',{'class':'kk-dji-signals'},[
                        E('div',{},[E('span',{},'RSRP'),E('strong',{id:'kk-dji-rsrp'},'—'),E('small',{},'接收信号强度')]),
                        E('div',{},[E('span',{},'RSRQ'),E('strong',{id:'kk-dji-rsrq'},'—'),E('small',{},'信号质量')]),
                        E('div',{},[E('span',{},'SINR'),E('strong',{id:'kk-dji-sinr'},'—'),E('small',{},'信噪比')]),
                        E('div',{},[E('span',{},'RSSI'),E('strong',{id:'kk-dji-rssi'},'—'),E('small',{},'总接收功率')])
                    ]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-signal-time'},'尚未读取信号')
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
                            E('div',{'class':'kk-dji-sms-detail-head'},[E('h3',{},'短信详情'),E('div',{'class':'kk-dji-actions'},[this.smsClearButton,this.smsDeleteButton])]),
                            this.smsDetailMeta,this.smsDetailBody,this.smsForm
                        ])
                    ]),
                    E('p',{'class':'kk-dji-note',id:'kk-dji-sms-note'},'等待检测短信能力。')
                ],'kk-dji-sms-card'),
                card('网页电话','当前模块通话条件检查与接听方案。',[
                    E('div',{'class':'kk-dji-call-state'},[E('strong',{id:'kk-dji-call-title'},'尚未验证双向音频'),E('span',{id:'kk-dji-call-subtitle'},'网页拨号暂不开放')]),
                    E('div',{'class':'kk-dji-actions'},[this.voiceProbeButton]),this.voiceStatus,
                    E('p',{'class':'kk-dji-note'},'未来可在设备具备通话控制和 USB 双向音频后，以浏览器响铃通知来电、点击接听/挂断；浏览器麦克风需要 HTTPS 和授权。')
                ],'kk-dji-phone-card'),
                card('定位','定位功能取决于模块固件和天线，首次锁定可能需要一段时间。',[
                    E('div',{'class':'kk-dji-rows'},[row('GPS 状态','kk-dji-gps-state'),row('定位结果','kk-dji-gps-fix'),row('经纬度','kk-dji-gps-coords'),row('速度','kk-dji-gps-speed'),row('更新时间','kk-dji-gps-time')]),
                    E('div',{'class':'kk-dji-actions'},[this.gpsStartButton,this.gpsStopButton]),
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
        poll.add(function(){return self.readSmsList(true);},60);
        Promise.resolve().then(function(){return self.readSmsList(true);});
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
            rsrp=first(radio.rsrp,modem.rsrp),rsrq=first(radio.rsrq,modem.rsrq),sinr=first(radio.sinr,radio.snr,modem.snr);
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
        this.set('kk-dji-rssi',metric(first(radio.rssi,modem.rssi),' dBm'));
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
            (forward.enabled?'新短信正文转发飞书已开启'+(forward.pending?'，待重试 '+forward.pending+' 条':'')+'。':'新短信飞书转发已关闭，可在“飞书推送”中开启。');
        var gpsSupported=gps.supported===true, gpsControl=caps.gps===true, gpsEnabled=gps.enabled===true;
        this.set('kk-dji-gps-state',!gpsSupported?'暂不可用':gpsEnabled?'已启动':'已关闭');
        this.set('kk-dji-gps-fix',!gpsSupported?'未检测':gps.fix===true?'已定位':gpsControl&&gpsEnabled?'等待定位':'未验收');
        this.set('kk-dji-gps-coords',gps.fix===true && gps.lat!=null && gps.lon!=null?metric(gps.lat,'',5)+', '+metric(gps.lon,'',5):null);
        this.set('kk-dji-gps-speed',gps.fix===true?metric(gps.speed_kmh,' km/h',1):null);
        this.set('kk-dji-gps-time',gps.fix===true?clock(gps.updated_at):null);
        this.gpsStartButton.hidden=!gpsControl || caps.gps_start!==true || gpsEnabled;
        this.gpsStopButton.hidden=!gpsControl || caps.gps_stop!==true || !gpsEnabled;
        this.gpsStartButton.disabled=this.gpsStopButton.disabled=!gpsControl || this.operating===true;
        this.el('kk-dji-gps-note').textContent=!gpsSupported?'暂未检测到可用的定位命令。':!gpsControl?'定位命令可响应，但天线和实机定位尚未验收，暂不开放开关。':gps.fix===true?'定位数据只在当前页面展示，未启用轨迹记录。':gpsEnabled?'正在等待卫星定位；车内遮挡会影响首次锁定。':'需要时可手动启动定位。';
        this.set('kk-dji-parity-device',available?'已接入':'模块未连通');
        this.set('kk-dji-parity-sms',smsReadAvailable?'已接入 · 点击单条读取':'当前不可用');
        this.set('kk-dji-parity-reconnect',caps.reconnect===true?'已接入':'当前不可用');
        this.set('kk-dji-parity-notify',forward.enabled?'系统告警与新短信转发已接入':'系统告警已接入 · 短信转发未开启');
        this.set('kk-dji-parity-esim','当前未识别 eSIM 能力');
        this.set('kk-dji-parity-proxy','车载场景未启用');
        this.set('kk-dji-parity-voice',this.voiceResult?.ready===true?'已验证':this.voiceResult?'控制与音频未齐备':'待检测');
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
    checkVoice:function(){
        var self=this;this.voiceProbeButton.disabled=true;this.voiceStatus.textContent='正在只读检测通话控制与 USB 音频…';
        return voiceProbe().then(function(result){
            if(!result || result.ok!==true)throw Error(result && result.error || '检测失败');
            self.voiceResult=result;
            self.set('kk-dji-call-title',result.audio_usb_present && result.usb_voice_enabled?'音频条件待验证':'暂缺 USB 双向音频');
            self.set('kk-dji-call-subtitle','拨号与接听需模块音频、网关及 HTTPS 管理入口');
            self.voiceStatus.textContent='语音 USB 位：'+(result.usb_voice_enabled===true?'开':result.usb_voice_enabled===false?'关':'未知')+
                ' · IMS 配置：'+(result.ims_setting==null?'未知':result.ims_setting)+
                ' · USB 声卡：'+(result.audio_usb_present?'已枚举':'未枚举')+
                ' · 通话查询：'+(result.call_query_accepted?'有响应':'无响应')+
                '。当前没有可用的双向音频路径，暂不开放拨号。';
            self.set('kk-dji-parity-voice',result.ready===true?'已验证':'通话与音频条件不足');
        }).catch(function(error){self.voiceStatus.textContent='电话能力检测失败：'+(error.message || '未知错误');})
            .finally(function(){self.voiceProbeButton.disabled=false;});
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
            self.smsItems=messages;
            self.el('kk-dji-sms-count').textContent=messages.length+' 条会话 / '+reply.count+' 个存储槽';
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
        }).catch(function(err){if(self.smsRequestId===requestId && self.selectedSmsIndex===index)self.smsDetailBody.textContent='读取失败：'+(err.message || '未知错误');})
            .finally(function(){if(self.smsRequestId===requestId)self.smsReading=false;});
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
