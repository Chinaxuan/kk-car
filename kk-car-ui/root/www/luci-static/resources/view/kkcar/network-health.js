'use strict';
'require view';
'require rpc';
'require poll';
'require view.kkcar.console as consoleUI';

var read = rpc.declare({object:'kkhealth',method:'status',expect:{}});
var save = rpc.declare({object:'kkhealth',method:'save',params:['settings','revision'],expect:{}});
var check = rpc.declare({object:'kkhealth',method:'check',expect:{}});
var labels={healthy:'正常',degraded:'部分目标无响应',failed:'连续无响应',unavailable:'接口未就绪',paused:'已手动暂停',unknown:'待确认',disabled:'已关闭'};
var names={cellular:'4G 上网',ethernet:'有线 WAN',vpn:'公司 VPN',dns:'域名解析'};
var reasons={ready:'线路可用',no_address:'等待接口和地址',no_cable:'没有接入网线',lan_mode:'网口当前为 LAN',uplink_stale:'出口状态过期',not_connected:'隧道未建立',user_paused:'遵循手动暂停',status_unreadable:'状态未读到',all_targets_failed:'所有探测目标无响应',recovering:'恢复确认中',sim_absent:'未检测到 SIM',sim_blocked:'SIM 不可用',sim_pin_required:'SIM 需要 PIN',sim_puk_required:'SIM 需要 PUK'};
var guards={boot_grace:'开机等待期',cooldown:'重连冷却中',hour_limit:'已到每小时限额',manual_operation:'其他手动操作正在进行',uplink_settling:'出口正在切换',uplink_stale:'出口状态未确认',vpn_paused:'VPN 已手动暂停',status_unreadable:'接口状态未确认',cellular_paused_or_initializing:'蜂窝已暂停或正在拨号',call_active:'正在通话或来电',call_unknown:'无法确认通话状态',settings_changed:'设置已改变',probe_recovered:'重新检查已恢复',physical_failed:'上网线路尚未恢复',observe_only:'本轮只读验证'};
var actions={vpn_initiate:'发起 VPN 连接',vpn_reconnect:'重建 VPN 数据隧道',cellular_reconnect:'重新拨号 4G'};
function timeLabel(t){return t?new Date(t*1000).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}):'—';}
function button(text,handler,kind){return E('button',{type:'button','class':'kk-button '+(kind||''),click:handler},text);}
function nav(path,text,active){return E('a',{href:L.url('admin/'+path),'class':active?'active':'','aria-current':active?'page':null},text);}

return view.extend({
 handleSave:null,handleSaveApply:null,handleReset:null,
 load:function(){return read();},
 render:function(data){
  var self=this;
  document.title='KK-Car · 网络守护';
  ['overview.css','network-health.css'].forEach(function(name){document.head.appendChild(E('link',{rel:'stylesheet',href:L.resource('view/kkcar/'+name)+'?v=20260927-health1'}));});
  this.inputs={};this.cards={};this.saving=false;
  this.notice=E('div',{'class':'kk-notice',role:'status','aria-live':'polite',hidden:true});
  this.updated=E('span',{},'正在读取');
  var cards=E('div',{'class':'kh-cards'});
  Object.keys(names).forEach(function(name){
   var state=E('strong',{'class':'kh-state'},'待确认'),detail=E('p',{},''),targets=E('div',{'class':'kh-targets'}),rounds=E('small',{},'');
   var card=E('section',{'class':'kh-card','data-state':'unknown'},[E('div',{'class':'kh-card-label'},[E('span',{},names[name]),E('b',{'class':'kh-selected'},'')]),state,detail,targets,rounds]);
   self.cards[name]={root:card,state:state,detail:detail,targets:targets,rounds:rounds};cards.appendChild(card);
  });
  this.summary=E('p',{'class':'kh-recovery-summary'},'读取恢复策略…');
  this.timeline=E('div',{'class':'kh-timeline'});
  function checkbox(key,title,hint){var input=E('input',{type:'checkbox'});self.inputs[key]=input;return E('label',{'class':'kh-switch'},[input,E('span',{},[E('strong',{},title),E('small',{},hint)])]);}
  function number(key,title,min,max,unit){var input=E('input',{type:'number',min:min,max:max,step:1,required:true});self.inputs[key]=input;return E('label',{'class':'kh-number'},[E('span',{},title),E('div',{},[input,E('small',{},unit)])]);}
  function targets(key,title,hint){var input=E('textarea',{rows:2,spellcheck:false,placeholder:'每行一个 IPv4 地址',required:true});self.inputs[key]=input;return E('label',{'class':'kh-addresses'},[E('strong',{},title),input,E('small',{},hint)]);}
  this.saveButton=button('保存策略',function(){self.store();},'primary');
  this.checkButton=button('立即探测',function(){self.request(check(),'已安排下一轮探测，结果会自动更新。');});
  var form=E('form',{'class':'kh-policy',submit:function(e){e.preventDefault();self.store();}},[
   E('h2',{},'检测与恢复'),
   checkbox('enabled','启用持续检测','关闭后保留现有网络连接和历史记录。'),
   checkbox('recover_vpn','VPN 自动恢复','上网线路可用且 VPN 连续无响应时，先发起连接或重建数据隧道；手动暂停后保持暂停。'),
   checkbox('recover_cellular','4G 自动重新拨号','默认关闭。开启后，仅在 4G 为当前出口、确认没有通话且不在初始化时尝试重新拨号。'),
   E('div',{'class':'kh-number-grid'},[
    number('interval_seconds','检测间隔',30,300,'秒'),number('fail_rounds','连续失败',3,10,'轮'),
    number('recover_rounds','恢复确认',2,5,'轮'),number('cooldown_seconds','重连冷却',300,3600,'秒'),
    number('max_actions_hour','每小时重连上限',1,4,'次'),number('boot_grace_seconds','开机等待',120,600,'秒')]),
   E('details',{'class':'kh-advanced'},[E('summary',{},'探测目标设置'),
    targets('wan_targets','上网线路 · 2–4 个地址','分别绑定物理上网接口发出，建议选择至少两个允许 Ping 的稳定目标。'),
    targets('vpn_targets','VPN · 2–4 个地址','强制经 ikecar 发出；应包含公司内网和 VPN 出口可达目标。不会回落到普通上网线路。')]),
   E('p',{'class':'kh-boundary'},'单个目标无响应只提示异常；全部目标连续失败才触发恢复。DNS 失败仅记录。自动恢复不操作 Wi-Fi、DHCP、USB 供电或整机重启。'),
   E('div',{'class':'kk-actions'},[this.saveButton,button('重新读取设置',function(){if(window.confirm('重新读取会放弃当前未保存的修改。'))self.reload();})])
  ]);
  this.root=E('div',{'class':'kk-app kk-studio kh-app'},[
   this.notice,
   E('div',{'class':'kh-toolbar'},[E('div',{},[E('span',{'class':'kh-eyebrow'},'CONTINUOUS HEALTH'),this.updated]),E('div',{'class':'kk-actions'},[this.checkButton])]),
   E('div',{'class':'kh-layout'},[
    E('main',{},[cards,E('section',{'class':'kh-history'},[E('div',{'class':'kh-history-head'},[E('h2',{},'故障与恢复记录'),E('small',{},'本机保留 · 最近 80 条')]),this.summary,this.timeline])]),
    E('aside',{},form)
   ]),E('p',{'class':'kh-footer'},'探测响应不能保证所有网站和业务可用。无响应可能是目标禁止 Ping；请结合网络检查、信号参数和历史记录判断。')
  ]);
  this.fill(data);this.paint(data);poll.add(function(){return self.refresh();},5);
  return consoleUI.mount(this.root, {
   page:'kkcar_health',title:'网络守护',description:'多目标检测、故障记录与受控恢复 · 区分线路、隧道和解析',
   status:this.updated,actions:[this.checkButton]
  });
 },
 fill:function(data){
  this.revision=data.revision;
  var self=this,s=data.settings||{};Object.keys(this.inputs).forEach(function(key){var input=self.inputs[key],value=s[key];if(input.type==='checkbox')input.checked=value===true;else input.value=Array.isArray(value)?value.join('\n'):value;});
 },
 request:function(promise,message){
  var self=this;return promise.then(function(r){if(!r.ok)throw new Error(r.error||'操作未完成');self.show(message,false);return self.refresh();}).catch(function(e){self.show(e.message||'请求失败',true);});
 },
 show:function(text,bad){this.notice.textContent=text;this.notice.hidden=false;this.notice.className='kk-notice '+(bad?'error':'');},
 store:function(){
  if(this.saving)return;
  if(!this.root.querySelector('form').reportValidity())return;
  var self=this,values={};Object.keys(this.inputs).forEach(function(key){var input=self.inputs[key];values[key]=input.type==='checkbox'?input.checked:input.type==='number'?Number(input.value):input.value.trim().split(/[\s,，]+/).filter(Boolean);});
  if(values.recover_cellular && !this.loadedCellular && !window.confirm('启用后，4G 连续故障时可能会短暂中断网络和 VPN。已有通话或状态不明确时跳过；仍可从此页关闭。'))return;
  this.saving=true;this.saveButton.disabled=true;
  save(JSON.stringify(values),this.revision).then(function(r){if(!r.ok)throw new Error(r.error||'保存失败');self.fill(r);self.loadedCellular=r.settings.recover_cellular;self.show('策略已保存并读回；下一轮检测采用新设置。',false);return self.refresh();})
  .catch(function(e){self.show(e.message||'保存失败',true);}).finally(function(){self.saving=false;self.saveButton.disabled=false;});
 },
 reload:function(){var self=this;read().then(function(d){if(!d.ok)throw new Error(d.error||'读取失败');self.fill(d);self.paint(d);self.show('已读取设备上的设置。',false);}).catch(function(e){self.show(e.message,true);});},
 refresh:function(){var self=this;return read().then(function(d){if(!d.ok)throw new Error(d.error||'读取失败');self.paint(d);}).catch(function(){self.updated.textContent='连接中断 · 保留上次结果';self.root.classList.add('kh-stale');self.checkButton.disabled=true;});},
 paint:function(data){
  var self=this,s=data.status||{},settings=data.settings||{},fresh=s.fresh===true;
  this.loadedCellular=settings.recover_cellular===true;
  this.root.classList.remove('kh-stale');this.checkButton.disabled=!fresh;
  this.updated.textContent=(fresh?(s.enabled?'每 '+settings.interval_seconds+' 秒检测':'检测已关闭'):'守护服务未更新')+' · '+timeLabel(s.timestamp);
  Object.keys(names).forEach(function(name){
   var card=self.cards[name],row=name==='dns'?(s.dns||{}):(s.groups||{})[name]||{},state=fresh?(row.state||'unknown'):'unknown';
   card.root.dataset.state=state;card.state.textContent=labels[state]||'待确认';
   card.root.querySelector('.kh-selected').textContent=s.active===name?'当前出口':'';
   card.detail.textContent=!fresh?'缓存过期，请检查服务':name==='dns'?'本机 DNS · '+(row.target||'www.baidu.com'):(reasons[row.reason]||'正在检查')+(row.device?' · '+row.device:'');
   card.targets.replaceChildren();(row.targets||[]).forEach(function(t){card.targets.appendChild(E('div',{'class':'kh-target','data-ok':fresh && t.ok===true?'yes':fresh && t.ok===false?'no':'unknown'},[E('span',{},t.target),E('b',{},!fresh?'过期':t.ok===true?(t.latency_ms==null?'有响应':t.latency_ms.toFixed(1)+' ms'):t.ok===false?'无响应':'未探测')]));});
   card.rounds.textContent=!fresh?'':name==='dns'?'只告警，不自动修改 DNS':(row.total?row.responding+'/'+row.total+' 个目标响应 · ':'')+'成功 '+(row.good||0)+' / 失败 '+(row.bad||0)+' 轮';
  });
  var last=s.last_action;
  this.summary.textContent='VPN 恢复 '+(settings.recover_vpn?'开启':'关闭')+' · 4G 重拨 '+(settings.recover_cellular?'开启':'关闭')+' · 本小时尝试 '+(s.actions_hour||0)+'/'+settings.max_actions_hour+
   (s.candidate?' · '+(actions[s.candidate]||s.candidate)+(s.suppressed?'：'+(guards[s.suppressed]||'暂缓'):''):'')+
   (last?' · 最近动作 '+timeLabel(last.timestamp)+' '+(actions[last.action]||'')+'（'+(last.accepted?'指令已提交，仍需探测验证':'指令未完成')+'）':'');
  this.timeline.replaceChildren();var records=data.events||[];
  if(!records.length)this.timeline.appendChild(E('p',{'class':'kk-empty'},'暂无记录；状态变化和恢复动作会保存在设备上。'));
  records.forEach(function(e){var text=e.event==='health'?(names[e.group]||'网络')+' · '+(labels[e.state]||'待确认')+(e.reason?' · '+(reasons[e.reason]||e.reason):''):e.event==='recovery'?(actions[e.action]||'恢复')+' · '+(e.accepted?'指令已提交':'指令未完成'):e.event==='service_start'?'网络守护启动':e.event==='collector_error'?'采集异常，等待下轮重试':'状态记录';self.timeline.appendChild(E('div',{'class':'kh-event','data-state':e.state||''},[E('time',{},timeLabel(e.timestamp)),E('span',{},text)]));});
 }
});
