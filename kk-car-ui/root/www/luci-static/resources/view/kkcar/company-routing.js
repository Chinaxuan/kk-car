'use strict';
'require view';
'require rpc';
'require poll';
'require view.kkcar.console_20261015 as consoleUI';

var get = rpc.declare({object:'kkroute',method:'status',expect:{}});
var save = rpc.declare({object:'kkroute',method:'save',params:['settings','revision'],expect:{}});
function button(label, fn, primary) { return E('button',{type:'button',class:'kr-button'+(primary?' primary':''),click:fn},label); }
function timeText(value) { return value ? new Date(value*1000).toLocaleTimeString('zh-CN',{hour12:false}) : '尚未查询'; }

return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){return get();},
    render:function(data){
        var self=this;
        document.title='KK-Car · 公司白名单';
        document.head.appendChild(E('link',{rel:'stylesheet',href:L.resource('view/kkcar/company-routing.css')+'?v=20261031-1'}));
        this.notice=E('div',{class:'kr-notice',role:'status','aria-live':'polite',hidden:true});
        this.summary=E('div',{class:'kr-summary','aria-live':'polite'});
        this.updated=E('span',{},'正在读取');
        this.enabled=E('input',{type:'checkbox','aria-label':'启用公司白名单'});
        this.dns=E('input',{type:'text',placeholder:'留空使用当前 VPN 的公共 DNS',maxlength:15,'aria-label':'公司内网 DNS'});
        this.entries=E('textarea',{rows:4,placeholder:'portal.example.com\n10.9.20.31\n10.9.20.0/24','aria-label':'新增域名或 IP，每行一条',spellcheck:'false'});
        this.note=E('input',{type:'text',maxlength:80,placeholder:'例如：公司门户（选填）','aria-label':'新规则备注'});
        this.rows=E('div',{class:'kr-rules'});
        this.count=E('span');
        this.saveButton=button('保存并应用',function(){self.save();},true);
        this.reloadButton=button('重新读取',function(){
            if(self.dirty&&!window.confirm('放弃未保存的修改，重新读取设备规则？'))return;
            get().then(function(d){self.bind(d);self.paint(d);}).catch(function(){self.message('读取失败，请检查连接',true);});
        });
        this.enabled.addEventListener('change',function(){self.changed();});
        this.dns.addEventListener('input',function(){self.changed();});
        var root=E('div',{class:'kr-page'},[
            this.notice,this.summary,
            E('section',{class:'kr-toolbar'},[
                E('label',{class:'kr-check'},[this.enabled,E('span',{},'启用公司白名单')]),
                E('p',{},'命中白名单的流量优先走当前选中的公司 VPN，覆盖国内 IP 直连规则。')
            ]),
            E('div',{class:'kr-layout'},[
                E('section',{class:'kr-panel'},[
                    E('div',{class:'kr-heading'},[E('h2',{},'我的规则'),this.count]),
                    this.rows,
                    E('div',{class:'kr-savebar'},[this.saveButton,E('span',{},'修改后保存；生效状态见上方。')])
                ]),
                E('aside',{class:'kr-panel'},[
                    E('h2',{},'添加规则'),
                    E('label',{class:'kr-field'},[E('span',{},'域名、IPv4 地址或网段'),this.entries]),
                    E('p',{class:'kr-hint'},'每行一条，可一次粘贴多条。域名包含其全部子域名；不要填写网址路径或端口。'),
                    E('label',{class:'kr-field'},[E('span',{},'备注'),this.note]),
                    button('加入列表',function(){self.add();}),
                    E('details',{class:'kr-advanced'},[
                        E('summary',{},'公司内网 DNS（可选）'),
                        E('label',{class:'kr-field'},[E('span',{},'DNS 服务器 IPv4 地址'),this.dns]),
                        E('p',{class:'kr-hint'},'仅用于白名单域名，查询通过公司 VPN 发送。公司内部域名无法解析时，可填写公司 DNS 地址。')
                    ]),
                    E('div',{class:'kr-notes'},[
                        E('h3',{},'使用说明'),
                        E('p',{},'域名在解析完成后自动更新 IP；下方显示实际学到的地址。共享同一 IP 的其他网站也可能走公司出口。'),
                        E('p',{},'终端应使用 KK-Car 的 DNS。浏览器自带的安全 DNS、已有缓存和旧连接可能绕过新域名规则；保存后可重新打开网站。'),
                        E('p',{},'192.168 网段继续走本地，不允许加入。当前仅支持 IPv4。VPN 不可用时，白名单流量不会自动改走公网。')
                        ,E('p',{},'增删或启停域名时，DNS 服务会短暂刷新；Wi-Fi 和 VPN 不会重连，已有地址租约保留。')
                    ])
                ])
            ])
        ]);
        this.bind(data);this.paint(data);
        poll.add(function(){return get().then(function(d){self.paint(d);}).catch(function(){self.updated.textContent='设备读取中断';});},5);
        return consoleUI.mount(root,{page:'kkcar_routing',title:'公司白名单',description:'手动指定走公司 VPN 的域名与 IP · 跟随双 VPN 自动选路',status:this.updated,actions:[this.reloadButton]});
    },
    message:function(text,error){this.notice.hidden=false;this.notice.className='kr-notice'+(error?' error':'');this.notice.textContent=text;},
    changed:function(){this.dirty=true;this.saveButton.disabled=!!this.busy;},
    bind:function(data){
        if(!data.ok){this.message(data.error||'读取失败',true);this.saveButton.disabled=true;return;}
        this.base=data.config;this.items=JSON.parse(JSON.stringify(data.config.rules));
        this.enabled.checked=data.config.enabled;this.dns.value=data.config.dns_server||'';this.dirty=false;
        this.saveButton.disabled=true;this.drawRows(data.runtime||{});
    },
    add:function(){
        var values=this.entries.value.split(/\r?\n/).map(function(s){return s.trim();}).filter(Boolean);
        if(!values.length){this.entries.focus();return false;}
        if(this.items.length+values.length>128){this.message('最多保存 128 条规则',true);return false;}
        var seen=new Set(this.items.map(function(r){return r.value.toLowerCase().replace(/^\*\./,'').replace(/\.$/,'');}));
        var added=[];
        for(var value of values){
            var key=value.toLowerCase().replace(/^\*\./,'').replace(/\.$/,'');
            if(seen.has(key)){this.message('重复规则：'+value,true);return false;}
            seen.add(key);added.push({value:value,enabled:true,note:this.note.value.trim()});
        }
        this.items.push.apply(this.items,added);this.entries.value='';this.note.value='';this.changed();this.drawRows(this.runtime||{});
        this.message('已加入 '+added.length+' 条，点击“保存并应用”生效。',false);
        return true;
    },
    drawRows:function(runtime){
        var self=this;
        this.count.textContent=this.items.length+' / 128 条';
        if(!this.items.length){this.rows.replaceChildren(E('div',{class:'kr-empty'},[E('strong',{},'还没有手动规则'),E('p',{},'在右侧添加公司域名或 IP，保存后优先通过公司 VPN 访问。')]));return;}
        this.rows.replaceChildren.apply(this.rows,this.items.map(function(row,index){
            var toggle=E('input',{type:'checkbox',checked:row.enabled,'aria-label':'启用 '+row.value});
            toggle.addEventListener('change',function(){row.enabled=toggle.checked;self.changed();});
            var value=E('input',{type:'text',value:row.value,maxlength:253,'aria-label':'规则 '+(index+1)+' 地址',spellcheck:'false'});
            value.addEventListener('input',function(){row.value=value.value;self.changed();});
            var note=E('input',{type:'text',value:row.note,placeholder:'添加备注',maxlength:80,'aria-label':'规则 '+(index+1)+' 备注'});
            note.addEventListener('input',function(){row.note=note.value;self.changed();});
            var state=E('p',{class:'kr-row-state','data-value':row.value});
            var remove=button('删除',function(){self.items.splice(index,1);self.changed();self.drawRows(self.runtime||{});});
            remove.setAttribute('aria-label','删除 '+row.value);
            return E('div',{class:'kr-row'},[E('label',{class:'kr-switch'},toggle),E('div',{class:'kr-row-fields'},[value,note,state]),remove]);
        }));
        this.paintRows(runtime);
    },
    paintRows:function(runtime){
        var self=this;
        this.rows.querySelectorAll('.kr-row-state').forEach(function(node,index){
            var row=self.items[index],r=(runtime.resolved||{})[node.dataset.value];
            if(!row.enabled||!self.enabled.checked)node.textContent=self.dirty?'已停用（尚未保存）':'已停用';
            else if(self.dirty)node.textContent='有未保存修改';
            else if(row.kind==='ip')node.textContent='IPv4 目标 · '+(self.applied?'已应用':'等待应用');
            else if(r&&r.error)node.textContent='解析失败：'+r.error;
            else if(r&&r.addresses&&r.addresses.length)node.textContent=r.addresses.join('、')+' · '+timeText(r.updated);
            else node.textContent='域名及子域名 · 等待通过 KK-Car 查询';
        });
    },
    save:function(){
        var self=this;if(this.busy)return;
        if(this.entries.value.trim()&&!this.add())return;
        this.busy=true;this.saveButton.disabled=true;this.saveButton.textContent='正在保存…';
        var input={enabled:this.enabled.checked,dns_server:this.dns.value,rules:this.items};
        save(JSON.stringify(input),this.base.revision).then(function(r){
            if(!r.ok)throw Error(r.error||'保存失败');
            return get();
        }).then(function(d){
            self.bind(d);self.pendingRevision=d.config.revision;self.paint(d);
            if(!d.applied)self.message('配置已保存，后台正在应用；请看上方生效状态。',false);
        }).catch(function(e){self.message(e.message||'保存失败',true);self.saveButton.disabled=false;})
        .finally(function(){self.busy=false;self.saveButton.textContent='保存并应用';if(self.dirty)self.saveButton.disabled=false;});
    },
    paint:function(data){
        if(!data.ok){this.message(data.error||'状态读取失败',true);return;}
        if(!this.dirty&&this.base&&data.config.revision!==this.base.revision)this.bind(data);
        this.runtime=data.runtime||{};this.applied=data.applied;
        var runtime=this.runtime,config=data.config;
        if(this.pendingRevision===config.revision){
            if(runtime.error)this.message('配置已保存，但应用失败：'+runtime.error,true);
            else if(data.applied){this.message('规则已生效。新的访问按公司白名单分流。',false);this.pendingRevision=null;}
        }
        var label=!data.running?'服务未运行':runtime.error?'应用失败':data.applied?(config.enabled?'已生效':'白名单已停用'):'正在应用';
        this.updated.textContent='更新于 '+timeText(runtime.timestamp);
        this.summary.replaceChildren(
            E('div',{},[E('span',{},'配置状态'),E('strong',{class:runtime.error||!data.running?'warning':'good'},label),E('small',{},runtime.error||'已保存版本 '+config.revision+' / 已应用 '+(runtime.applied_revision==null?'—':runtime.applied_revision))]),
            E('div',{},[E('span',{},'公司出口'),E('strong',{},runtime.device==='wgcar'?'WireGuard':runtime.device==='ovpncar'?'OpenVPN / TCP':'读取中'),E('small',{},'随自动选路切换，隧道是否可用请看连接设置')]),
            E('div',{},[E('span',{},'启用规则'),E('strong',{},String(config.enabled?config.rules.filter(function(r){return r.enabled;}).length:0)),E('small',{},'域名优先解析并写入路由，再返回终端')])
        );
        this.paintRows(runtime);
    }
});
