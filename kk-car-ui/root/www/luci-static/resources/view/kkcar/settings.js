'use strict';
'require view';
'require rpc';
'require poll';
'require view.kkcar.console as consoleUI';

var get=rpc.declare({object:'kksettings',method:'status',expect:{}});
var getFrame=rpc.declare({object:'kksettings',method:'epaper_frame',expect:{}});
var save=rpc.declare({object:'kksettings',method:'save',params:['settings','revision'],expect:{}});
var serviceSet=rpc.declare({object:'kksettings',method:'service_set',params:['name','action','expected'],expect:{}});
var clean=rpc.declare({object:'kksettings',method:'refresh_screen',expect:{}});
var carGet=rpc.declare({object:'kkcar',method:'status',expect:{}});
var upsGet=rpc.declare({object:'kkups',method:'status',expect:{}});
var carAuto=rpc.declare({object:'kkcar',method:'auto_connect',params:['enabled'],expect:{}});
var upsOption=rpc.declare({object:'kkups',method:'set_option',params:['key','value','expected','confirm'],expect:{}});

var fields=[
 ['rotation','显示方向',[[0,'正常 0°'],[180,'反转 180°']],'改变画面方向，四个按键的功能保持不变。'],
 ['refresh_seconds','数据刷新间隔',[[60,'1 分钟'],[180,'3 分钟'],[300,'5 分钟'],[600,'10 分钟']],'定时读取最新状态并全屏刷新；电子纸断电仍保留最后一帧。'],
 ['grayscale','屏幕灰阶',null,'灰阶全刷时，文字边缘和分隔线使用深灰；关闭后使用黑白全刷。'],
 ['fast_refresh','按键快速刷新',null,'开启时翻页使用黑白快刷，深灰笔画和线条会映射成黑色；关闭后按键全刷，画面更统一但等待更长。'],
 ['partial_refresh','菜单局部刷新',null,'选中标记小范围更新；仅在快速刷新开启时有效。'],
 ['clean_after','连续快速更新后清屏',[[1,'1 次'],[2,'2 次'],[3,'3 次']],'最多三次，之后自动全刷抑制残影。'],
 ['sleep_seconds','屏幕控制器休眠延迟',[[18,'18 秒'],[30,'30 秒'],[60,'60 秒']],'无按键更新后休眠；仍定时刷新、仍可按键唤醒。'],
 ['start_page','开机首页',[[1,'行车总览'],[2,'蜂窝网络'],[3,'VPN'],[4,'短信与流量'],[5,'电源'],[6,'系统']],'下次显示服务启动时使用；KEY1 始终返回行车总览。'],
 ['auto_page_seconds','自动翻页',[[0,'关闭'],[60,'每 1 分钟'],[180,'每 3 分钟'],[300,'每 5 分钟']],'按键后重新计时；设置菜单中暂停自动翻页。'],
 ['hdmi_refresh_seconds','HDMI 刷新间隔',[[5,'5 秒'],[10,'10 秒'],[15,'15 秒'],[30,'30 秒'],[60,'60 秒']],'保持当前 1080p；较长间隔可降低显示服务占用。'],
 ['check_interval_seconds','自动网络检查周期',[[300,'5 分钟'],[600,'10 分钟'],[900,'15 分钟'],[1800,'30 分钟'],[3600,'60 分钟']],'服务开启时生效，包含网络连通性及 ChatGPT / Gemini 区域检查。']
];
var serviceInfo={
 'network-health':['网络守护','持续检测上网线路、VPN 和 DNS；暂停后不会自动恢复连接，已有连接保持。'],
 'epaper':['电子纸与四键','暂停后画面保留，屏幕按键失效；可在后台重新启动。'],
 'hdmi':['HDMI 状态看板','只影响本地显示，暂停后恢复文字控制台。'],
 'auto-check':['自动网络检查','关闭后不再定时检查；手动网络检查仍可使用。'],
 'diagnostics':['每分钟故障记录','保留现有记录；暂停后不再采集，恢复后继续记录。'],
 'modem':['4G 状态采集','暂停后信号、频段等状态会过期；不改变蜂窝拨号配置。'],
 'vpn-ping':['VPN 延迟与丢包采集','暂停后延迟和历史图表该项不再更新，不停止 VPN。'],
 'notify':['飞书事件推送','暂停后不再检测网络、电源、终端等事件。具体事件与地址在通知中心。'],
 'dji-sms-forward':['短信归档与转发','暂停后不再自动归档新短信和转发，可能导致模块短信仓满。'],
 'voice-runtime':['SIM 通话与来电监测','暂停后不再自动监测来电和维护模块通话路由。'],
 'voice-gateway':['网页双向语音','暂停会断开网页声音。已有通话可能仍在模块中，请先挂断。']
};
function nav(path,title,active){return E('a',{href:L.url('admin/'+path),'class':'ku-nav-item'+(active?' active':''),'aria-current':active?'page':null},title);}
function button(text,handler){return E('button',{type:'button','class':'ku-button',click:handler},text);}
function stamp(v){return v?new Date(v*1000).toLocaleTimeString('zh-CN',{hour12:false}):'尚无数据';}

return view.extend({
 handleSaveApply:null,handleSave:null,handleReset:null,
 load:function(){return Promise.all([get(),carGet(),upsGet()]);},
 render:function(data){
  var self=this;document.title='KK-Car · 设置中心';this.inputs={};this.dirty=false;this.last=data[0];this.base=data[0];
  document.head.appendChild(E('link',{rel:'stylesheet',href:L.resource('view/kkcar/ups.css')+'?v=20260927-settings'}));
  document.head.appendChild(E('link',{rel:'stylesheet',href:L.resource('view/kkcar/settings.css')+'?v=20260928-mirror1'}));
  this.notice=E('div',{'class':'ku-notice',hidden:true,role:'status','aria-live':'polite'});
  this.mirrorImage=E('img',{alt:'电子纸最近一次成功写入的画面',hidden:true});
  this.mirrorInfo=E('p',{'class':'ks-mirror-info','aria-live':'polite'},'正在读取墨水屏画面…');
  this.mirrorNode=E('div',{'class':'ks-mirror'},[
   E('div',{'class':'ks-mirror-stage'},this.mirrorImage),
   E('div',{'class':'ks-mirror-meta'},[this.mirrorInfo,button('更新镜像',function(){self.refreshMirror();})])
  ]);
  this.updated=E('span',{},'读取中');
  this.summary=E('div',{'class':'ks-summary'});this.services=E('div',{'class':'ks-service-list'});
  this.saveButton=button('保存显示与检查设置',function(){self.saveSettings();});
  this.reloadButton=button('重新读取',function(){if(self.dirty&&!window.confirm('放弃尚未保存的设置并读取设备当前值？'))return;get().then(function(d){self.bind(d);self.paint(d);}).catch(function(){self.message('设置读取失败，请稍后重试',true);});});
  this.cleanButton=button('立即全屏清理残影',function(){self.run(function(){return clean();},'已请求清屏；请等待当前写屏完成。');});
  function formField(f){
   var input=f[2]?E('select',{'aria-label':f[1]},f[2].map(function(o){return E('option',{value:o[0]},o[1]);})):E('input',{type:'checkbox','aria-label':f[1]});
   input.addEventListener('change',function(){self.dirty=true;self.saveButton.disabled=false;self.updateDependencies();});self.inputs[f[0]]=input;
   return E('label',{'class':'ks-field'},[E('span',{},[E('strong',{},f[1]),E('small',{},f[3])]),input]);
  }
  var controls=E('div',{'class':'ks-setting-grid'},[
   E('section',{'class':'ku-panel'},[E('h2',{},'电子纸与按键'),E('p',{'class':'ku-helper'},'屏幕菜单与本页共用配置。KEY1 首页 / 返回，KEY2 上，KEY3 下，KEY4 设置 / 确认。'),this.mirrorNode].concat(fields.slice(0,9).map(formField))),
   E('section',{'class':'ku-panel'},[E('h2',{},'HDMI 与自动检查')].concat(fields.slice(9).map(formField),[E('div',{'class':'ks-readback'},[E('strong',{},'设置如何生效'),E('p',{},'方向、灰阶和刷新设置在当前写屏结束后应用；开机首页在下次显示服务启动时生效。HDMI 周期在下一帧应用，自动检查周期最多等待 15 秒。')]),
    E('h3',{},'常用控制'),this.quick=E('div',{'class':'ks-quick'}),E('p',{'class':'ku-helper'},'UPS 电池基准、保护电压和低电策略使用电源页原有的读回与确认。')]))]);
  var catalogue=[
   ['kkcar_health','网络守护','多目标探测、故障分类、VPN 自动恢复与可选 4G 重拨；设置连续轮数、冷却和每小时限额。'],
   ['kkcar_connections','网络与连接','VPN 启停与重连、开机自动连接、Wi-Fi 名称与密码、2.4 / 5 GHz、LAN / WAN、网络检查和维护。'],
   ['kkcar_dji','蜂窝与通信','GPS 启停、定位刷新、数据网络重连、短信发送 / 归档 / 删除、联系人与通话、运营商查询命令与每日流量校正。'],
   ['kkcar_ups','UPS 电源','来电自启、采样周期、RTC 校时、低电策略、满电 / 空电 / 保护电压、用户电池参数、重启 / 关机与倒计时。'],
   ['kkcar_notifications','通知与机器人','总开关、各事件开关、各推送地址开关、WebHook、延迟 / 丢包 / 信号 / 温度等阈值、冷却时间与测试推送。']
  ];
  var root=E('div',{'class':'ku-shell ks-shell'},[
   E('main',{'class':'ku-main'},[E('header',{'class':'ku-header'},[E('div',{},[E('span',{'class':'ku-eyebrow'},'DEVICE SETTINGS'),E('h1',{},'设置中心'),E('p',{},'显示、诊断、后台服务与各模块控制')]),E('div',{'class':'ku-header-actions'},[this.reloadButton,this.cleanButton])]),this.notice,this.summary,controls,
    E('div',{'class':'ks-save-bar'},[this.saveButton,E('span',{},'仅保存修改的字段；不会重启网络、Wi-Fi 或 VPN。')]),
    E('section',{'class':'ku-panel'},[E('div',{'class':'ku-panel-title'},[E('h2',{},'后台服务'),E('span',{},'运行状态与开机启动独立设置')]),this.job=E('p',{'class':'ku-helper','aria-live':'polite'}),this.services]),
    E('section',{'class':'ks-catalogue'},catalogue.map(function(c){return E('a',{href:L.url('admin/'+c[0])},[E('strong',{},c[1]+' →'),E('p',{},c[2])]);}))])]);
  this.bind(data[0]);this.paint(data[0]);this.paintQuick(data[1],data[2]);
  this.refreshMirror();
  poll.add(function(){return get().then(function(d){self.paint(d);}).catch(function(){self.updated.textContent='读取中断 · 保留上次状态';self.message('设备状态暂时无法读取，已有设置未改动',true);});},5);
  poll.add(function(){return self.refreshMirror();},10);
  return consoleUI.mount(root, {
   page:'kkcar_settings',title:'设置中心',description:'屏幕、自动检查和后台服务 · 设置保存在路由器上',
   status:this.updated,actions:[this.reloadButton,this.cleanButton]
  });
 },
 message:function(text,error){this.notice.hidden=false;this.notice.className='ku-notice'+(error?' error':'');this.notice.textContent=text;},
 refreshMirror:function(){
  var self=this;
  return getFrame().then(function(frame){
   if(!frame||!frame.ok){self.mirrorImage.hidden=true;self.mirrorInfo.textContent=frame&&frame.error||'屏幕尚未生成画面';return;}
   if(self.mirrorUpdated!==frame.updated||self.mirrorData!==frame.data){
    self.mirrorImage.src='data:image/png;base64,'+frame.data;
    self.mirrorImage.hidden=false;
    self.mirrorUpdated=frame.updated;self.mirrorData=frame.data;
   }
   self.mirrorInfo.textContent='最近写入 '+stamp(frame.updated)+' · 第 '+frame.page+' 页 · '+(frame.view==='pages'?'状态页':'设置界面')+' · '+frame.rotation+'°';
  }).catch(function(){self.mirrorInfo.textContent='墨水屏镜像暂时无法读取';});
 },
 bind:function(data){if(!data.ok){this.message(data.error||'无法读取设置',true);this.saveButton.disabled=true;return;}this.base=data;this.dirty=false;this.saveButton.disabled=true;for(var k in this.inputs){var input=this.inputs[k];if(input.type==='checkbox')input.checked=data.settings[k];else input.value=data.settings[k];}this.updateDependencies();},
 updateDependencies:function(){this.inputs.partial_refresh.disabled=!this.inputs.fast_refresh.checked;this.inputs.clean_after.disabled=!this.inputs.fast_refresh.checked;},
 run:function(task,message){var self=this;if(this.busy)return Promise.resolve();this.busy=true;return task().then(function(r){if(!r||!r.ok)throw Error(r&&r.error||'操作失败');self.message(message,false);return get().then(function(d){self.paint(d);});}).catch(function(e){self.message(e.message,true);}).finally(function(){self.busy=false;});},
 saveSettings:function(){
  var self=this,changes={};for(var k in this.inputs){var input=this.inputs[k],value=input.type==='checkbox'?input.checked:Number(input.value);if(value!==this.base.settings[k])changes[k]=value;}
  if(!Object.keys(changes).length){this.dirty=false;this.saveButton.disabled=true;return;}
  this.saveButton.disabled=true;
  this.run(function(){return save(JSON.stringify(changes),self.base.revision);},'配置已保存，应用状态见上方。').then(function(){return get();}).then(function(d){if(d.revision===self.base.revision+1&&Object.keys(changes).every(function(k){return d.settings[k]===changes[k];}))self.bind(d);else self.saveButton.disabled=false;}).catch(function(){self.saveButton.disabled=false;});
 },
 changeService:function(s,action){
  if(this.busy||this.last.busy)return;
  var description=serviceInfo[s.name][1],verb=({start:'启动',stop:'暂停',restart:'重启',enable:'开启开机启动',disable:'关闭开机启动'})[action];
  if(!window.confirm(verb+'「'+serviceInfo[s.name][0]+'」？\n'+description))return;
  var self=this;this.run(function(){return serviceSet(s.name,action,['enable','disable'].includes(action)?s.enabled:s.running);},'操作已提交；完成情况以服务运行状态和任务结果为准。');
 },
 paintQuick:function(car,ups){
  var self=this;this.quick.replaceChildren();
  if(car.vpn){this.quick.appendChild(button(car.vpn.auto?'关闭 VPN 开机连接':'开启 VPN 开机连接',function(){self.run(function(){return carAuto(!car.vpn.auto);},'VPN 开机连接设置已保存').then(function(){return Promise.all([carGet(),upsGet()]);}).then(function(d){self.paintQuick(d[0],d[1]);});}));}
  if(ups.ok){this.quick.appendChild(button(ups.controller.auto_start_on_ac?'关闭 UPS 来电自启':'开启 UPS 来电自启',function(){if(ups.controller.auto_start_on_ac===false&&!window.confirm('电池电压过低时，来电自动启动可能再次造成开机循环。确定开启？'))return;self.run(function(){return upsOption('auto_start_on_ac',ups.controller.auto_start_on_ac?0:1,ups.controller.auto_start_on_ac?1:0,'');},'UPS 来电自启已写入并读回').then(function(){return Promise.all([carGet(),upsGet()]);}).then(function(d){self.paintQuick(d[0],d[1]);});}));}
  this.quick.appendChild(E('a',{'class':'ku-button',href:L.url('admin/kkcar_dji')+'#gps'},'GPS 与通信设置 →'));
 },
 paint:function(d){
  if(!d.ok){this.message(d.error||'无法读取设备设置',true);return;}
  this.updated.textContent='更新于 '+stamp(d.timestamp);
  this.last=d;if(!this.dirty&&d.revision!==this.base.revision)this.bind(d);
  var self=this,ep=d.epaper||{},hd=d.hdmi||{},epService=(d.services||[]).find(function(s){return s.name==='epaper';}),hdService=(d.services||[]).find(function(s){return s.name==='hdmi';});
  var applied=epService&&epService.running&&ep.state==='ok'&&ep.settings_revision===d.revision;
  function metric(label,value,note){return E('div',{},[E('span',{},label),E('strong',{},value),E('small',{},note)]);}
  this.summary.replaceChildren(metric('电子纸方向',d.settings.rotation+'°',applied?'屏幕已应用 · '+stamp(ep.updated):epService&&epService.running?'等待显示服务应用':'显示服务未运行'),metric('定时数据刷新',d.settings.refresh_seconds/60+' 分钟','按键仍可即时操作'),metric('HDMI',hdService&&hdService.running?'运行中':'已暂停',hdService&&hdService.running?'最近写屏 '+stamp(hd.timestamp):'画面可能保留旧数据'),metric('自动网络检查',d.check.enabled&&(d.services||[]).some(function(s){return s.name==='auto-check'&&s.running;})?'已开启':'已暂停','设置周期 '+d.settings.check_interval_seconds/60+' 分钟'));
  this.job.textContent=d.busy?'正在执行服务操作，请等待…':d.job.state==='error'?'最近操作失败：'+d.job.error:d.job.state==='done'?'最近服务操作已完成 · '+stamp(d.job.timestamp):'暂停采集不会清空已有历史；开机启动开关不改变当前运行状态。';
  this.services.replaceChildren.apply(this.services,(d.services||[]).map(function(s){
   var meta=serviceInfo[s.name],disabled=!s.installed||!s.known||d.busy;
   var run=button(s.running?'暂停':'启动',function(){self.changeService(s,s.running?'stop':'start');});run.disabled=disabled;
   var boot=button(s.enabled?'关闭自启':'开启自启',function(){self.changeService(s,s.enabled?'disable':'enable');});boot.disabled=disabled;
   var restart=button('重启',function(){self.changeService(s,'restart');});restart.disabled=disabled||!s.running;
   return E('div',{'class':'ks-service'},[E('div',{},[E('strong',{},meta[0]),E('small',{},meta[1])]),E('div',{'class':'ks-service-state'},[E('span',{'class':'ks-pill '+(s.running?'on':'off')},!s.installed?'未安装':!s.known?'状态未知':s.running?'运行中':'已暂停'),E('small',{},'开机启动 '+(s.enabled?'开':'关'))]),E('div',{'class':'ks-service-buttons'},[run,boot,restart])]);
  }));
 }
});
