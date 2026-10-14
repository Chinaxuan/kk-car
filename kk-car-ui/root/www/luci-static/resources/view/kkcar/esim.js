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
function card(title,desc,content){return E('section',{'class':'kk-esim-card'},[E('div',{'class':'kk-esim-card-head'},[E('h2',{},title),E('p',{},desc)])].concat(content));}

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return status();},
    render:function(initial){
        var self=this;
        document.title='KK-Car · 副卡与 eSIM';
        if(!document.getElementById('kk-esim-css'))document.head.appendChild(E('link',{id:'kk-esim-css',rel:'stylesheet',href:L.resource('view/kkcar/esim.css')+'?v=20261015'}));
        this.updated=E('span',{},'正在读取');
        this.notice=E('p',{'class':'kk-esim-notice',role:'status','aria-live':'polite',hidden:true});
        this.device=E('div',{'class':'kk-esim-device'},'正在读取副卡模块…');
        this.profileList=E('div',{'class':'kk-esim-profiles'},'正在读取卡内配置…');
        this.auto=E('input',{type:'checkbox','aria-label':'自动轮换已选配置'});
        this.interval=E('input',{type:'number',min:'30',max:'1440',step:'1',value:'60','aria-label':'轮换间隔分钟'});
        this.settingsDirty=false;
        this.auto.addEventListener('change',function(){self.settingsDirty=true;});
        this.interval.addEventListener('input',function(){self.settingsDirty=true;});
        this.saveButton=button('保存自动切卡',function(){self.saveSettings();},'primary');
        this.smsStatus=E('p',{},'正在读取短信…');
        this.smsItems=E('div',{'class':'kk-esim-sms-items'},'正在读取短信目录…');
        this.smsDetail=E('div',{'class':'kk-esim-detail','aria-live':'polite'},'选择短信查看正文。');
        this.to=E('input',{type:'tel',inputmode:'tel',autocomplete:'off',maxlength:16,placeholder:'接收号码','aria-label':'接收号码'});
        this.message=E('textarea',{rows:3,maxlength:70,placeholder:'单条最多 70 字，不支持 emoji','aria-label':'短信内容'});
        this.sendButton=button('用副卡发送短信',function(){self.sendMessage();},'primary');
        var root=E('div',{'class':'kk-esim kk-app'},[
            this.notice,
            E('div',{'class':'kk-esim-grid'},[
                card('第二只 DJI 模块','专用于 eSIM 与短信；不会参与 WAN、VPN 选路或移动数据连接。',[
                    this.device,E('p',{'class':'kk-esim-foot'},'不配置副卡移动数据与 WAN；发现其数据接口时由守护服务关闭。')]),
                card('eSIM 配置','卡内所有配置只读取名称与末四位；切换只启用已存在的配置，不删除或下载。',[
                    this.profileList,E('div',{'class':'kk-esim-settings'},[
                        E('label',{},[this.auto,E('span',{},'启用自动轮换')]),
                        E('label',{},[E('span',{},'每隔多少分钟'),this.interval]),this.saveButton]),
                    E('p',{'class':'kk-esim-foot'},'至少有两个配置且勾选轮换对象后才能开启。当前只有一个配置时不会切卡。')]),
                card('副卡短信','短信保存在卡内，同时加密归档到树莓派；有新短信时沿用通知中心的飞书设置。',[
                    this.smsStatus,E('div',{'class':'kk-esim-actions'},[button('刷新短信',function(){self.loadMessages();})]),
                    E('div',{'class':'kk-esim-inbox'},[this.smsItems,this.smsDetail])]),
                card('发送短信','只使用第二张卡，可能产生运营商短信费用。发送结果不确定时请先核查，避免重复发送。',[
                    E('div',{'class':'kk-esim-compose'},[this.to,this.message,this.sendButton])])
            ])
        ]);
        this.paint(initial);
        this.loadMessages();
        poll.add(function(){return status().then(function(data){self.paint(data);}).catch(function(){self.updated.textContent='状态读取中断';});},30);
        poll.add(function(){return self.loadMessages();},60);
        return consoleUI.mount(root,{page:'kkcar_esim',title:'副卡与 eSIM',
            description:'第二只 DJI 模块 · 卡内配置、自动切卡与短信',status:this.updated});
    },
    show:function(text,error){this.notice.hidden=false;this.notice.classList.toggle('error',!!error);this.notice.textContent=text;},
    paint:function(data){
        this.latest=data||{};
        var available=!!data&&data.ok===true&&data.present===true;
        this.updated.textContent=available?'副卡已连接 · '+new Date().toLocaleTimeString('zh-CN',{hour12:false}):'副卡未连接';
        var sms=data&&data.sms||{},profiles=data&&Array.isArray(data.profiles)?data.profiles:[];
        this.device.replaceChildren(
            E('div',{'class':'kk-esim-kpis'},[
                E('div',{},[E('span',{},'模块'),E('strong',{},available?'已识别':'未识别')]),
                E('div',{},[E('span',{},'移动数据'),E('strong',{'class':'kk-esim-safe'},data&&data.data_devices&&data.data_devices.length?'发现数据接口，已阻断':'未建立')]),
                E('div',{},[E('span',{},'卡内配置'),E('strong',{},String(profiles.length))]),
                E('div',{},[E('span',{},'短信仓'),E('strong',{},sms.capacity?value(sms.used)+' / '+value(sms.capacity):'—')])
            ]),data&&data.error?E('p',{'class':'kk-esim-warn'},data.error):'',
            data&&data.rotation_status?E('p',{'class':'kk-esim-warn'},'自动切卡：'+data.rotation_status):'');
        if(!this.settingsDirty){
            this.auto.checked=data&&data.auto===true;
            this.interval.value=String(data&&data.interval_minutes||60);
            this.selectedRotation=new Set(data&&Array.isArray(data.rotation)?data.rotation:[]);
        }
        this.auto.disabled=profiles.length<2;
        this.saveButton.disabled=!available;
        this.profileList.replaceChildren();
        if(!profiles.length)this.profileList.appendChild(E('p',{},available?'没有读到卡内配置':'插入第二只模块后显示配置。'));
        profiles.forEach(function(item){
            var checkbox=E('input',{type:'checkbox',
                'aria-label':'将 '+value(item.name)+' 加入自动轮换',change:function(){
                    this.settingsDirty=true;
                    if(checkbox.checked)this.selectedRotation.add(item.token);else this.selectedRotation.delete(item.token);
                }.bind(this)});
            checkbox.checked=this.selectedRotation.has(item.token);
            var action=button(item.enabled?'当前使用':'切换到此配置',function(){this.switchTo(item);}.bind(this));
            action.disabled=item.enabled||profiles.length<2;
            this.profileList.appendChild(E('div',{'class':'kk-esim-profile'},[
                E('div',{},[E('strong',{},item.name||item.provider||'未命名配置'),
                    E('small',{},value(item.provider)+' · 尾号 '+value(item.last4)),
                    E('span',{'class':item.enabled?'kk-esim-current':'kk-esim-idle'},item.enabled?'已启用':'未启用')]),
                E('div',{'class':'kk-esim-profile-actions'},[E('label',{},[checkbox,E('span',{},'自动轮换')]),action])
            ]));
        },this);
        this.smsStatus.textContent=!available?'副卡未连接':sms.error?'短信：'+sms.error:
            '未读 '+value(sms.unread)+' 条 · '+(sms.updated_at?'最近检查 '+new Date(sms.updated_at*1000).toLocaleTimeString('zh-CN',{hour12:false}):'等待首次检查');
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
        this.show('正在切换并核对卡内状态…',false);
        return switchProfile(item.token).then(function(result){
            if(!result.ok)throw Error(result.error||'切卡未确认');
            return status().then(function(current){self.paint(current);self.show('已切换到 '+value(item.name)+'，卡内启用状态已读回。',false);});
        }).catch(function(error){self.show(error.message,true);});
    },
    loadMessages:function(){
        var self=this;
        return Promise.all([smsList(),smsHistory()]).then(function(results){
            var directory=results[0],history=results[1];
            if(!directory.ok){self.smsItems.textContent=directory.error||'短信暂不可读';return;}
            var groups=Array.isArray(directory.groups)?directory.groups:[];
            var archive=history.ok&&Array.isArray(history.entries)?history.entries:[];
            self.smsItems.replaceChildren();
            if(!groups.length&&!archive.length){self.smsItems.textContent='暂无短信';return;}
            groups.slice().reverse().forEach(function(group){
                self.smsItems.appendChild(button((group.ui_unread?'● ':'')+value(group.from)+' · '+value(group.time),
                    function(){self.openGroup(group);}));
            });
            archive.slice().reverse().filter(function(item){return !groups.some(function(g){return g.badge_id===item.id;});}).forEach(function(item){
                self.smsItems.appendChild(button((item.unread?'● ':'')+value(item.from)+' · '+value(item.time),
                    function(){self.openArchive(item);}));
            });
        }).catch(function(){self.smsItems.textContent='短信读取中断，请稍后刷新';});
    },
    openGroup:function(group){
        var self=this,parts=Array.isArray(group.parts)?group.parts:[group.index];
        this.smsDetail.textContent='正在读取短信…';
        return Promise.all(parts.map(function(i){return smsRead(String(i));})).then(function(items){
            if(items.some(function(item){return !item.ok||!item.message;}))throw Error('短信内容暂不可读');
            self.smsDetail.replaceChildren(E('strong',{},value(group.from)),E('p',{},items.map(function(item){return item.message.text||'';}).join('')));
            if(group.badge_id)smsAck(group.badge_id).catch(function(){});
        }).catch(function(error){self.smsDetail.textContent=error.message;});
    },
    openArchive:function(item){
        var self=this;this.smsDetail.textContent='正在解密历史短信…';
        return smsHistoryRead(item.id).then(function(result){
            if(!result.ok)throw Error(result.error||'历史短信暂不可读');
            self.smsDetail.replaceChildren(E('strong',{},value(result.message.from)),E('p',{},result.message.text||''));
            smsAck(item.id).catch(function(){});
        }).catch(function(error){self.smsDetail.textContent=error.message;});
    },
    sendMessage:function(){
        var self=this;
        this.sendButton.disabled=true;
        return smsSend(this.to.value.trim(),this.message.value).then(function(result){
            if(!result.ok)throw Error(result.error||'发送未确认');
            self.message.value='';self.show('短信已由副卡模块提交，编号 '+value(result.reference)+'。',false);
            return self.loadMessages();
        }).catch(function(error){self.show(error.message,true);}).finally(function(){self.sendButton.disabled=false;});
    }
});
