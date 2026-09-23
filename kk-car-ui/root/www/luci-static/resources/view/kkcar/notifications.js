'use strict';
'require view';
'require rpc';
'require poll';
var get=rpc.declare({object:'kkcar',method:'notify_get',expect:{}});
var save=rpc.declare({object:'kkcar',method:'notify_save',params:['settings'],expect:{}});
var test=rpc.declare({object:'kkcar',method:'notify_test',expect:{}});
var events=[['vpn_up','VPN 上线'],['vpn_down','VPN 下线'],['boot','正常开机'],['shutdown','正常关机 / 重启'],['abnormal_boot','异常断电后启动'],['client_join','设备接入'],['client_leave','设备离线'],['uplink','有线 / 4G 出口变化'],['latency','VPN 延迟过高'],['loss','VPN 持续丢包'],['signal','蜂窝信号偏弱'],['power','树莓派欠压'],['temperature','处理器高温'],['recovery','异常恢复通知'],['sms_received','DJI 新短信正文']];
var limits=[['latency_ms','延迟阈值 · ms',50,5000],['loss_percent','丢包阈值 · %',1,100],['hold_seconds','异常持续 · 秒',10,600],['cooldown_seconds','同类间隔 · 秒',60,86400],['signal_dbm','弱信号阈值 · dBm',-140,-60],['temperature_c','高温阈值 · °C',50,95]];
function check(id,text,on) {var input=E('input',{type:'checkbox',id:id});input.checked=!!on;return {input:input,node:E('label',{'class':'kk-check',for:id},[input,E('span',{},text)])};}
function section(title,nodes){return E('section',{'class':'kk-section'},[E('div',{'class':'kk-section-head'},E('h2',{},title))].concat(nodes));}
return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return get();},
    render:function(data){
        var self=this,c=data.config;this.fields={};this.switches={};this.targets=[];
        document.title='KK-Car · 飞书推送';
        ['overview','notifications'].forEach(function(n){var id='kk-css-'+n;if(!document.getElementById(id))document.head.appendChild(E('link',{id:id,rel:'stylesheet',href:L.resource('view/kkcar/'+n+'.css')}));});
        this.master=check('notify-enabled','启用飞书推送',c.enabled);
        this.notice=E('p',{'class':'kk-notice',role:'status','aria-live':'polite',hidden:true});
        this.status=E('div',{'class':'kk-push-status','aria-live':'polite'});
        this.saveButton=E('button',{type:'submit','class':'kk-button primary'},'保存推送设置');
        this.testButton=E('button',{type:'button','class':'kk-button',click:function(){self.perform(test(),'测试已排队，请看下方各地址的发送结果。');}},'发送测试通知');
        var eventNodes=events.map(function(e){var f=check('notify-'+e[0],e[1],c.events[e[0]]);self.switches[e[0]]=f.input;return f.node;});
        var thresholdNodes=limits.map(function(l){var f=E('input',{id:'notify-'+l[0],type:'number',min:l[2],max:l[3],step:1,value:c[l[0]],required:true});self.fields[l[0]]=f;return E('label',{'class':'kk-push-field',for:'notify-'+l[0]},[E('span',{},l[1]),f]);});
        var destinations=c.destinations.map(function(d,i){
            var on=check('notify-dest-'+i,'启用此地址',d.enabled),clear=check('notify-clear-'+i,'清除已存地址',false);
            var name=E('input',{id:'notify-name-'+i,type:'text',value:d.name,maxlength:60,autocomplete:'off'});
            var url=E('input',{id:'notify-url-'+i,type:'password',autocomplete:'new-password',placeholder:d.configured?'已保存，留空保留原地址':'粘贴飞书 Webhook',spellcheck:'false'});
            var configured=E('span',{'class':'kk-muted'},d.configured?'地址已保存':'尚未配置');
            self.targets.push({id:d.id,on:on.input,clear:clear.input,name:name,url:url,configured:configured});
            return E('div',{'class':'kk-push-destination'},[
                E('div',{'class':'kk-push-dest-head'},[E('strong',{},'推送地址 '+(i+1)),configured,on.node]),
                E('div',{'class':'kk-push-address'},[
                    E('label',{'class':'kk-push-field',for:'notify-name-'+i},[E('span',{},'地址名称'),name]),
                    E('label',{'class':'kk-push-field',for:'notify-url-'+i},[E('span',{},'Webhook · 不回显'),url])]),clear.node]);
        });
        var form=E('form',{submit:function(e){e.preventDefault();self.submit();}},[
            E('div',{'class':'kk-push-toolbar'},[this.master.node,E('div',{'class':'kk-actions'},[this.saveButton,this.testButton])]),
            E('div',{'class':'kk-push-grid'},[
                E('div',{},[section('通知事件',[E('div',{'class':'kk-push-events'},eventNodes)]),section('告警阈值',[E('div',{'class':'kk-push-limits'},thresholdNodes),E('p',{'class':'kk-footnote'},'延迟、丢包、高温需持续达到阈值；弱信号至少持续 60 秒。恢复采用回落区间，减少边缘反复提醒。')])]),
                section('飞书机器人地址',destinations.concat([E('p',{'class':'kk-footnote'},'三个地址独立启停，开启的地址接收相同事件。短信正文可能含验证码，只会发到已启用地址；历史短信不会补发。留空保留，勾选清除后保存才删除。')]))
            ])
        ]);
        var root=E('div',{'class':'kk-app kk-studio kk-push'},[
            E('div',{'class':'kk-header'},[E('div',{},[E('h1',{},'飞书推送'),E('p',{'class':'kk-muted'},'变化才提醒，恢复有回音')]),E('a',{'class':'kk-button',href:L.url('admin/kkcar')},'返回网络面板')]),
            this.notice,form,section('发送状态',[this.status]),
            E('p',{'class':'kk-footnote'},'突然断电无法即时推送，下次开机补报。断网时通知在内存中保留最多 50 条、1 小时，网络恢复后重试；断电会丢失待发队列。正常关机只做有限时长的发送尝试。'),
            E('p',{'class':'kk-footnote'},'Wi-Fi 按实时关联检测，有线设备按新鲜邻居记录判断；安静设备可能延迟识别。初次启用不逐台通知现有设备。通知不包含公网 IP 或密钥。')
        ]);
        this.paint(data);poll.add(function(){return get().then(function(d){self.paint(d);}).catch(function(){self.status.textContent='暂时无法读取发送状态，页面内容可能已过期。';});},5);
        return root;
    },
    perform:function(promise,message){var self=this;this.saveButton.disabled=this.testButton.disabled=true;return promise.then(function(r){if(!r.ok)throw Error(r.error || '操作失败');self.notice.hidden=false;self.notice.className='kk-notice';self.notice.textContent=message;return r;}).catch(function(e){self.notice.hidden=false;self.notice.className='kk-notice error';self.notice.textContent=e.message;return null;}).finally(function(){self.saveButton.disabled=self.testButton.disabled=false;});},
    submit:function(){
        var self=this,c={enabled:this.master.input.checked,events:{},destinations:[]};
        events.forEach(function(e){c.events[e[0]]=self.switches[e[0]].checked;});
        limits.forEach(function(l){c[l[0]]=Number(self.fields[l[0]].value);});
        this.targets.forEach(function(d){c.destinations.push({id:d.id,name:d.name.value,enabled:d.on.checked,url:d.url.value.trim(),clear:d.clear.checked});});
        this.perform(save(JSON.stringify(c)),'推送设置已保存，后台约 10 秒内生效。').then(function(r){if(r){self.targets.forEach(function(d,i){d.url.value='';d.clear.checked=false;d.configured.textContent=r.config.destinations[i].configured?'地址已保存':'尚未配置';d.url.placeholder=r.config.destinations[i].configured?'已保存，留空保留原地址':'粘贴飞书 Webhook';});}});
    },
    paint:function(data){
        var s=data.status || {},c=data.config,stale=!s.timestamp || Date.now()/1000-s.timestamp>90;
        var rows=[E('p',{},!c.enabled?'推送已暂停':s.error || (stale?'后台状态未更新，请检查推送服务':s.sample_error?'监控数据暂不可用':'后台监控中')+' · 待发 '+(s.queued || 0)+' 条')];
        c.destinations.forEach(function(d){var r=s.deliveries && s.deliveries[d.id];rows.push(E('div',{'class':'kk-data-row'},[E('span',{},d.name),E('strong',{},!d.enabled?'地址已停用':!r?'尚未发送':(r.ok?'飞书已接收':'发送失败，将重试')+' · '+new Date(r.at*1000).toLocaleTimeString('zh-CN',{hour12:false})+(!r.ok?' · HTTP '+r.http+' / code '+r.code:''))]));});
        if(s.log && s.log.length)rows.push(E('p',{'class':'kk-footnote'},'最近成功：'+s.log[s.log.length-1].text));
        if(s.dropped)rows.push(E('p',{'class':'kk-footnote'},'队列达到上限，已丢弃最早的 '+s.dropped+' 条通知。'));
        this.status.replaceChildren.apply(this.status,rows);
    }
});
