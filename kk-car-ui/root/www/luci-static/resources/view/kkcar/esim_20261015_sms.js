'use strict';
'require view';
'require rpc';
'require poll';
'require view.kkcar.console_20261015 as consoleUI';

var status=rpc.declare({object:'kkesim',method:'status',expect:{}});
var save=rpc.declare({object:'kkesim',method:'save',params:['auto','interval_minutes','rotation'],expect:{}});
var switchProfile=rpc.declare({object:'kkesim',method:'switch',params:['token'],expect:{}});
var smsList=rpc.declare({object:'kkesim',method:'sms_list',expect:{}});
var smsRead=rpc.declare({object:'kkesim',method:'sms_read',params:['index'],expect:{}});
var smsHistory=rpc.declare({object:'kkesim',method:'sms_history',expect:{}});
var smsHistoryRead=rpc.declare({object:'kkesim',method:'sms_history_read',params:['id'],expect:{}});
var smsAck=rpc.declare({object:'kkesim',method:'sms_ack',params:['id'],expect:{}});
var smsSend=rpc.declare({object:'kkesim',method:'sms_send',params:['to','text'],expect:{}});
function button(text,click,kind){return E('button',{type:'button','class':'kk-button '+(kind||''),click:click},text);}
function value(x){return x===null||x===undefined||x===''?'—':String(x);}
function card(title,desc,content,kind){return E('section',{'class':'kk-esim-card '+(kind||'')},[E('div',{'class':'kk-esim-card-head'},[E('h2',{},title),E('p',{},desc)])].concat(content));}
function size(bytes){
    if(typeof bytes!=='number'||!isFinite(bytes)||bytes<0)return '—';
    if(bytes>=1073741824)return (bytes/1073741824).toFixed(1)+' GB';
    if(bytes>=1048576)return (bytes/1048576).toFixed(1)+' MB';
    return Math.ceil(bytes/1024)+' KB';
}

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return status();},
    render:function(initial){
        var self=this;
        document.title='KK-Car · 副卡短信';
        if(!document.getElementById('kk-esim-css'))document.head.appendChild(E('link',{id:'kk-esim-css',rel:'stylesheet',href:L.resource('view/kkcar/esim.css')+'?v=20261015-sms2'}));
        this.updated=E('span',{},'正在读取');
        this.notice=E('p',{'class':'kk-esim-notice',role:'status','aria-live':'polite',hidden:true});
        this.device=E('div',{'class':'kk-esim-device'},'正在读取副卡模块…');
        this.storage=E('div',{'class':'kk-esim-storage'},'正在核对树莓派存储…');
        this.profileList=E('div',{'class':'kk-esim-profiles'},'正在读取卡内配置…');
        this.auto=E('input',{type:'checkbox','aria-label':'自动轮换已选配置'});
        this.interval=E('input',{type:'number',min:'30',max:'1440',step:'1',value:'60','aria-label':'轮换间隔分钟'});
        this.settingsDirty=false;this.switching=false;this.selectedRotation=new Set();
        this.auto.addEventListener('change',function(){self.settingsDirty=true;});
        this.interval.addEventListener('input',function(){self.settingsDirty=true;});
        this.saveButton=button('保存自动切卡',function(){self.saveSettings();},'primary');
        this.smsStatus=E('p',{},'正在读取短信…');
        this.smsItems=E('div',{'class':'kk-esim-sms-items'},'正在读取短信目录…');
        this.smsDetail=E('div',{'class':'kk-esim-detail','aria-live':'polite'},'选择短信查看正文。');
        this.smsFilter=E('select',{'aria-label':'筛选短信'},[
            E('option',{value:'current'},'当前号码'),E('option',{value:'all'},'全部号码'),
            E('option',{value:'unread'},'未读短信')]);
        this.smsFilter.addEventListener('change',function(){self.paintMessages();});
        this.to=E('input',{type:'tel',inputmode:'tel',autocomplete:'off',maxlength:16,placeholder:'接收号码','aria-label':'接收号码'});
        this.message=E('textarea',{rows:3,maxlength:70,placeholder:'单条最多 70 字，不支持 emoji','aria-label':'短信内容'});
        this.sendButton=button('发送短信',function(){self.sendMessage();},'primary');
        var root=E('div',{'class':'kk-esim kk-app'},[
            this.notice,
            E('section',{'class':'kk-esim-hero'},this.device),
            E('div',{'class':'kk-esim-workspace'},[
                E('aside',{'class':'kk-esim-rail'},[
                    card('卡内号码','选择已经写入 eSIM 的配置。切换后当前号码会暂时离线。',[
                        this.profileList,E('details',{'class':'kk-esim-auto'},[
                            E('summary',{},'定时切卡'),E('div',{'class':'kk-esim-settings'},[
                        E('label',{},[this.auto,E('span',{},'启用自动轮换')]),
                        E('label',{},[E('span',{},'间隔（分钟）'),this.interval]),this.saveButton,
                        E('p',{},'至少选中两个配置并包含当前号码。')])])],'kk-esim-profiles-panel'),
                    card('存储空间','卡内暂存新短信，树莓派保留加密历史。',[this.storage],'kk-esim-storage-panel')]),
                E('div',{'class':'kk-esim-main'},[
                    card('收件箱','切换号码后，后台每分钟检查新短信。',[
                        E('div',{'class':'kk-esim-toolbar'},[this.smsStatus,
                            E('div',{},[this.smsFilter,button('刷新短信',function(){self.loadMessages();})])]),
                        E('div',{'class':'kk-esim-inbox'},[this.smsItems,this.smsDetail])],'kk-esim-inbox-panel'),
                    card('发送短信','仅用当前副卡号码发送。运营商可能收费；结果不明时请先核查。',[
                        E('div',{'class':'kk-esim-compose'},[this.to,this.message,this.sendButton])],'kk-esim-compose-panel')])
            ])
        ]);
        this.paint(initial);
        this.loadMessages();
        poll.add(function(){return status().then(function(data){self.paint(data);}).catch(function(){self.updated.textContent='状态读取中断';});},30);
        poll.add(function(){return self.loadMessages();},60);
        return consoleUI.mount(root,{page:'kkcar_esim',title:'副卡短信',
            description:'eSIM 切换、收件箱与加密存储',status:this.updated});
    },
    show:function(text,error){this.notice.hidden=false;this.notice.classList.toggle('error',!!error);this.notice.textContent=text;},
    paint:function(data){
        if(!data||data.ok!==true){this.updated.textContent='状态暂不可读';return;}
        this.latest=data||{};
        var available=!!data&&data.ok===true&&data.present===true;
        this.updated.textContent=available?'副卡已连接 · '+new Date().toLocaleTimeString('zh-CN',{hour12:false}):'副卡未连接';
        var sms=data.sms||{},profiles=Array.isArray(data.profiles)?data.profiles:[];
        var current=profiles.find(function(item){return item.enabled;})||null;
        var network=data.network||{},store=data.storage||{};
        this.activeToken=current?current.token:null;
        var registered=network.ok===true&&network.registered===true;
        var inboxReady=current&&sms.profile_token===current.token&&!sms.error&&
            (!data.last_switch||sms.updated_at>=data.last_switch);
        var networkText=!available?'副卡未连接':!current?'没有启用配置':network.ok!==true?'注册状态待确认':
            registered?(inboxReady?'已注册，可等待短信':'已注册，正在准备收件箱'):
            network.lte===3||network.circuit===3?'网络拒绝注册':'正在搜索网络';
        this.device.replaceChildren(
            E('div',{'class':'kk-esim-current-number'},[
                E('span',{},'当前收信号码'),
                E('strong',{},current?current.name||current.provider||'未命名配置':'未启用配置'),
                E('small',{},current?'配置尾号 '+value(current.last4):'请检查副卡模块与 eSIM')]),
            E('div',{'class':'kk-esim-hero-status'},[
                E('b',{'class':registered&&inboxReady?'good':network.ok===true?'warning':''},networkText),
                E('span',{},this.switching?'切换中，请稍候':registered&&inboxReady?'每分钟自动收信':
                    '已启用配置不等于完成网络注册；后台仍会定时检查。')]),
            E('div',{'class':'kk-esim-hero-facts'},[
                E('div',{},[E('span',{},'未读'),E('strong',{},sms.unread==null?'—':String(sms.unread))]),
                E('div',{},[E('span',{},'卡内仓位'),E('strong',{},sms.capacity>0?value(sms.used)+' / '+sms.capacity:'—')]),
                E('div',{},[E('span',{},'加密历史'),E('strong',{},value(store.history_count))]),
                E('div',{},[E('span',{},'SD 可用'),E('strong',{},size(store.free_bytes))])]),
            data.error?E('p',{'class':'kk-esim-warn'},data.error):'',
            data.rotation_status?E('p',{'class':'kk-esim-warn'},'自动切卡：'+data.rotation_status):'');
        var used=Number(sms.used),capacity=Number(sms.capacity);
        var percent=capacity>0&&isFinite(used)?Math.min(100,Math.max(0,used/capacity*100)):0;
        this.storage.replaceChildren(
            E('div',{'class':'kk-esim-storage-row'},[E('span',{},'SIM 暂存仓'),E('strong',{},capacity>0?used+' / '+capacity+' 格':'容量待读取')]),
            E('div',{'class':'kk-esim-meter',role:'meter','aria-label':'SIM 短信仓占用',
                'aria-valuemin':'0','aria-valuemax':String(capacity>0?capacity:0),
                'aria-valuenow':String(capacity>0?used:0)},E('span',{style:'width:'+percent+'%'})),
            E('div',{'class':'kk-esim-storage-row'},[E('span',{},'树莓派加密历史'),E('strong',{},value(store.history_count)+' 条')]),
            E('div',{'class':'kk-esim-storage-row'},[E('span',{},'SD 卡剩余'),E('strong',{},size(store.free_bytes))]),
            E('div',{'class':'kk-esim-storage-row'},[E('span',{},'加密文件占用'),
                E('strong',{},size((store.history_bytes||0)+(store.archive_bytes||0)))]),
            E('p',{'class':'kk-esim-storage-state '+(store.ready?'good':'warning')},
                store.ready?'加密存储已就绪':'存储或备份密钥待检查'),
            E('p',{'class':'kk-esim-foot'},'新完整短信先存入 SD 卡。归档和已启用的飞书投递成功后，才清理卡内新短信；旧短信与缺段短信保留。'));
        if(!this.settingsDirty){
            this.auto.checked=data&&data.auto===true;
            this.interval.value=String(data&&data.interval_minutes||60);
            this.selectedRotation=new Set(data&&Array.isArray(data.rotation)?data.rotation:[]);
        }
        this.auto.disabled=profiles.length<2;
        this.saveButton.disabled=!available||this.switching;
        this.profileList.replaceChildren();
        if(!profiles.length)this.profileList.appendChild(E('p',{},available?'没有读到卡内配置':'插入第二只模块后显示配置。'));
        profiles.forEach(function(item){
            var checkbox=E('input',{type:'checkbox',
                'aria-label':'将 '+value(item.name)+' 加入自动轮换',change:function(){
                    this.settingsDirty=true;
                    if(checkbox.checked)this.selectedRotation.add(item.token);else this.selectedRotation.delete(item.token);
                }.bind(this)});
            checkbox.checked=this.selectedRotation.has(item.token);
            var action=button(item.enabled?'当前使用':this.switching?'切换中…':'切换到此号码',
                function(){this.switchTo(item);}.bind(this),item.enabled?'':'primary');
            action.disabled=item.enabled||profiles.length<2||this.switching;
            this.profileList.appendChild(E('div',{'class':'kk-esim-profile'},[
                E('div',{},[E('strong',{},item.name||item.provider||'未命名配置'),
                    E('small',{},'标识尾号 '+value(item.last4)+(item.provider?' · '+item.provider:'')),
                    E('span',{'class':item.enabled?'kk-esim-current':'kk-esim-idle'},item.enabled?'已启用':'未启用')]),
                E('div',{'class':'kk-esim-profile-actions'},[E('label',{},[checkbox,E('span',{},'自动轮换')]),action])
            ]));
        },this);
        this.smsStatus.textContent=!available?'副卡未连接':sms.error?'短信检查异常：'+sms.error:
            (sms.updated_at?'最近检查 '+new Date(sms.updated_at*1000).toLocaleTimeString('zh-CN',{hour12:false}):'等待首次检查')+
            (inboxReady?' · 已核对当前号码':' · 当前号码目录待核对');
        if(this.messages)this.paintMessages();
    },
    saveSettings:function(){
        var self=this,interval=Number(this.interval.value),rotation=Array.from(this.selectedRotation);
        this.saveButton.disabled=true;
        return save(this.auto.checked,interval,rotation).then(function(result){
            if(!result.ok)throw Error(result.error||'保存失败');
            return status().then(function(current){self.settingsDirty=false;self.paint(current);self.show('自动切卡设置已保存并读回。',false);});
        }).catch(function(error){self.show(error.message,true);}).finally(function(){self.saveButton.disabled=false;});
    },
    switchTo:function(item){
        var self=this;
        if(this.switching)return;
        this.switching=true;this.paint(this.latest);
        this.show('正在启用「'+value(item.name)+'」并核对卡内配置…',false);
        return switchProfile(item.token).then(function(result){
            if(!result.ok)throw Error(result.error||'切卡未确认');
            return status().then(function(current){
                var active=(current.profiles||[]).find(function(profile){return profile.enabled;});
                if(!current.ok||!active||active.token!==item.token)throw Error('切卡结果未读回，请检查当前配置');
                self.paint(current);self.smsFilter.value='current';
                var ready=current.network&&current.network.registered&&current.sms&&
                    current.sms.profile_token===item.token&&!current.sms.error;
                self.show('已启用「'+value(item.name)+'」。'+
                    (ready?'收件箱已核对，等待新短信。':'正在核对网络及收件箱，后台继续检查短信。'),false);
                return self.loadMessages();
            });
        }).catch(function(error){self.show(error.message,true);}).finally(function(){
            self.switching=false;if(self.latest)self.paint(self.latest);
        });
    },
    loadMessages:function(){
        var self=this;
        return Promise.allSettled([smsList(),smsHistory()]).then(function(results){
            var directory=results[0].status==='fulfilled'?results[0].value:{ok:false};
            var history=results[1].status==='fulfilled'?results[1].value:{ok:false};
            if(!directory.ok&&!history.ok){self.smsItems.textContent='短信暂不可读，请稍后刷新';return;}
            var groups=directory.ok&&Array.isArray(directory.groups)?directory.groups:[];
            var archive=history.ok&&Array.isArray(history.entries)?history.entries:[];
            var archivedIds=new Set(archive.map(function(item){return item.id;}));
            self.messages=archive.map(function(item){return {kind:'history',data:item,
                profile_token:item.profile_token||null,unread:item.unread===true,sort:item.archived_at||0};});
            groups.filter(function(group){return !group.badge_id||!archivedIds.has(group.badge_id);})
                .forEach(function(group){self.messages.push({kind:'sim',data:group,
                    profile_token:self.activeToken,unread:group.ui_unread===true,
                    sort:(Date.parse(group.time)||0)/1000});});
            self.messages.sort(function(a,b){return b.sort-a.sort;});
            self.paintMessages();
        }).catch(function(){self.smsItems.textContent='短信读取中断，请稍后刷新';});
    },
    paintMessages:function(){
        var self=this,items=this.messages||[],filter=this.smsFilter.value;
        var profiles=this.latest&&Array.isArray(this.latest.profiles)?this.latest.profiles:[];
        var shown=items.filter(function(item){
            if(filter==='unread')return item.unread;
            if(filter==='all')return true;
            return item.profile_token===self.activeToken||!item.profile_token&&profiles.length===1;
        });
        this.smsItems.replaceChildren();
        if(!shown.length){this.smsItems.appendChild(E('div',{'class':'kk-esim-empty'},[
            E('strong',{},filter==='unread'?'没有未读短信':'这个号码还没有短信'),
            E('p',{},'后台每分钟检查一次。其他号码的历史可在「全部号码」查看。')]));return;}
        shown.forEach(function(item){
            var message=item.data;
            var owner=profiles.find(function(profile){return profile.token===item.profile_token;});
            var label=owner?(owner.name||owner.provider||'未命名配置')+' · '+owner.last4:
                item.profile_token?'其他配置':'旧记录';
            self.smsItems.appendChild(button([
                E('span',{'class':'kk-esim-message-top'},[
                    E('strong',{},value(message.from)),item.unread?E('i',{},'未读'):'']),
                E('span',{'class':'kk-esim-message-time'},value(message.time)),
                E('span',{'class':'kk-esim-message-source'},label+' · '+
                    (item.kind==='history'?'已加密保存':'卡内暂存'))],
                function(){if(item.kind==='history')self.openArchive(message);else self.openGroup(message);},
                'kk-esim-message-row'));
        });
    },
    openGroup:function(group){
        var self=this,parts=Array.isArray(group.parts)?group.parts:[group.index];
        this.smsDetail.textContent='正在读取短信…';
        return parts.reduce(function(chain,i){
            return chain.then(function(items){return smsRead(String(i)).then(function(item){items.push(item);return items;});});
        },Promise.resolve([])).then(function(items){
            if(items.some(function(item){return !item.ok||!item.message;}))throw Error('短信内容暂不可读');
            self.smsDetail.replaceChildren(E('small',{},value(group.time)+' · 卡内暂存'),
                E('strong',{},value(group.from)),E('p',{},items.map(function(item){return item.message.text||'';}).join('')));
            if(group.badge_id)smsAck(group.badge_id).then(function(){self.loadMessages();}).catch(function(){});
        }).catch(function(error){self.smsDetail.textContent=error.message;});
    },
    openArchive:function(item){
        var self=this;this.smsDetail.textContent='正在解密历史短信…';
        return smsHistoryRead(item.id).then(function(result){
            if(!result.ok)throw Error(result.error||'历史短信暂不可读');
            self.smsDetail.replaceChildren(E('small',{},value(result.message.time)+' · 树莓派加密历史'),
                E('strong',{},value(result.message.from)),E('p',{},result.message.text||''));
            if(item.unread)smsAck(item.id).then(function(){self.loadMessages();}).catch(function(){});
        }).catch(function(error){self.smsDetail.textContent=error.message;});
    },
    sendMessage:function(){
        var self=this;
        if(!this.to.value.trim()||!this.message.value){this.show('请填写接收号码和短信内容。',true);return;}
        if(!window.confirm('确认用当前副卡向 '+this.to.value.trim()+' 发送短信？运营商可能收费。'))return;
        this.sendButton.disabled=true;
        return smsSend(this.to.value.trim(),this.message.value).then(function(result){
            if(!result.ok)throw Error(result.error||'发送未确认');
            self.message.value='';self.show('短信已由副卡模块提交，编号 '+value(result.reference)+'。',false);
            return self.loadMessages();
        }).catch(function(error){self.show(error.message,true);}).finally(function(){self.sendButton.disabled=false;});
    }
});
