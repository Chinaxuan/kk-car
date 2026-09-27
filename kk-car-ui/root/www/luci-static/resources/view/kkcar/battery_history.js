'use strict';
'require baseclass';
'require rpc';
'require poll';

var read=rpc.declare({object:'kkups',method:'history',params:['range','start','end','segment','raw','offset'],expect:{}});
var modes={charge:'充电',discharge:'放电',idle:'外电 / 平衡',external:'外电 / 充电过程',unknown:'状态未知'};
var metrics={battery_a:{label:'电池电流',unit:'A',col:5,color:'#8edcc5',signed:true},
    battery_w:{label:'电池功率',unit:'W',col:6,color:'#8edcc5',signed:true},
    pi_w:{label:'Pi 耗电',unit:'W',col:8,color:'#f3c17a'},
    temperature_c:{label:'电池温度',unit:'°C',col:9,color:'#f3c17a'},
    percent_estimate:{label:'电量估计（未校准）',unit:'%',col:10,color:'#c4b3f8'},
    pi_v:{label:'Pi 供电电压',unit:'V',col:7,color:'#f3c17a'}};
function fmt(v,d){return Number.isFinite(v)?v.toFixed(d==null?2:d):'—';}
function date(t){return t?new Date(t*1000).toLocaleString('zh-CN',{hour12:false,month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}):'—';}
function span(s){return s>=3600?fmt(s/3600,1)+' 小时':Math.round(s/60)+' 分钟';}
function localInput(t){var d=new Date(t);return new Date(t-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}

var HistoryPanel=baseclass.extend({
    __init__:function(){
        var self=this;this.range='24h';this.segment=0;this.selected=0;this.metric='battery_a';this.request=0;
        this.status=E('span',{'class':'ku-history-status',role:'status','aria-live':'polite'},'正在读取历史记录…');
        this.summary=E('div',{'class':'ku-history-summary'});
        this.legend=E('div',{'class':'ku-history-legend'},[
            E('span',{'class':'ku-legend-controller'},'━ UPS 主控电压'),E('span',{'class':'ku-legend-sensor'},'┄ INA219 电池侧电压'),
            E('span',{'class':'ku-history-mode-key'},[
                E('span',{style:'color:#8edcc5'},'条带：充电'),E('span',{style:'color:#f3c17a'},' / 放电'),E('span',{style:'color:#9abbdc'},' / 外电平衡'),E('span',{},' / 未知')])]);
        this.voltageTitle=E('strong',{},'电池电压 · V');this.flowTitle=E('strong',{},'电池电流 · A');
        this.voltage=E('canvas',{tabindex:0,role:'img','aria-label':'电池电压历史曲线，左右方向键查看采样详情'});
        this.flow=E('canvas',{tabindex:0,role:'img','aria-label':'电池电流历史曲线，左右方向键查看采样详情'});
        this.details=E('div',{'class':'ku-history-details','aria-live':'polite'},'移动指针或用方向键查看采样详情');
        this.sessionSelect=E('select',{'aria-label':'充放电过程',change:function(){self.segment=Number(this.value);self.fetch();}});
        this.metricSelect=E('select',{'aria-label':'第二张曲线指标',change:function(){self.metric=this.value;self.draw();self.detail(self.selected);}},
            Object.keys(metrics).map(function(key){return E('option',{value:key},metrics[key].label+' · '+metrics[key].unit);}));
        this.exportButton=E('button',{'class':'ku-button',type:'button',disabled:true,click:function(){self.exportCsv();}},'导出原始数据 CSV');
        this.start=E('input',{type:'datetime-local',value:localInput(Date.now()-86400000),'aria-label':'曲线开始时间'});
        this.end=E('input',{type:'datetime-local',value:localInput(Date.now()),'aria-label':'曲线结束时间'});
        this.buttons={};
        var ranges=E('div',{'class':'ku-history-ranges','aria-label':'历史时间范围'},[['1h','1 小时'],['24h','1 天'],['7d','7 天'],['30d','30 天'],['all','全部记录']].map(function(r){
            var b=E('button',{type:'button','class':'ku-button','aria-pressed':r[0]===self.range?'true':'false',click:function(){self.range=r[0];self.segment=0;self.fetch();}},r[1]);self.buttons[r[0]]=b;return b;
        }));
        this.node=E('section',{'class':'ku-panel ku-history'},[
            E('div',{'class':'ku-history-heading'},[E('div',{},[E('h2',{},'充放电分析'),E('p',{},'读取 SD 卡每分钟保存的历史日志')]),this.exportButton]),
            E('div',{'class':'ku-history-toolbar'},[ranges,this.sessionSelect,
                E('button',{'class':'ku-button',type:'button',click:function(){self.fetch();}},'刷新曲线')]),
            E('div',{'class':'ku-history-dates'},[E('label',{},[E('span',{},'开始'),this.start]),E('label',{},[E('span',{},'结束'),this.end]),
                E('button',{'class':'ku-button',type:'button',click:function(){if(!self.start.value||!self.end.value){self.status.textContent='请填写开始与结束时间';return;}self.range='custom';self.segment=0;self.fetch();}},'查看区间'),this.status]),
            this.summary,this.legend,
            E('div',{'class':'ku-history-plots'},[
                E('div',{'class':'ku-history-plot'},[E('div',{'class':'ku-history-plot-title'},[this.voltageTitle,E('span',{},'两路原始读数 · 自动缩放')]),this.voltage]),
                E('div',{'class':'ku-history-plot'},[E('div',{'class':'ku-history-plot-title'},[this.flowTitle,this.metricSelect]),this.flow])]),
            this.details,
            E('div',{'class':'ku-history-note'},'正电流为充电，负电流为放电；断电、重启、时钟跳变及超过 3 分钟的空档不连线。电流、功率与积分均未校准，不能据此认定真实容量或完整续航。'),
            E('div',{'class':'ku-history-retention'})]);
        this.retention=this.node.lastChild;
        [this.voltage,this.flow].forEach(function(canvas){
            canvas.addEventListener('pointermove',function(event){if(!self.data||!self.data.points.length)return;var rect=canvas.getBoundingClientRect();var x=(event.clientX-rect.left-48)/(rect.width-62);self.nearest(x);});
            canvas.addEventListener('keydown',function(event){if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();self.detail(self.selected+(event.key==='ArrowLeft'?-1:1));self.draw();}});
        });
        this.observer=new ResizeObserver(function(){if(self.data)self.draw();});this.observer.observe(this.node);
        poll.add(function(){return self.fetch(true);},60);
        this.fetch();
    },
    fetch:function(quiet){
        var self=this,id=++this.request;
        if(!quiet)this.status.textContent='正在读取历史记录…';
        Object.keys(this.buttons).forEach(function(k){self.buttons[k].setAttribute('aria-pressed',k===self.range?'true':'false');});
        var start=this.range==='custom'?Math.floor(new Date(this.start.value).getTime()/1000):0;
        var end=this.range==='custom'?Math.floor(new Date(this.end.value).getTime()/1000):0;
        if(!Number.isFinite(start)||!Number.isFinite(end)||(this.range==='custom'&&start>=end)){this.status.textContent='开始时间应早于结束时间';return Promise.resolve();}
        return read(this.range,start,end,this.segment,false,0).then(function(data){
            if(id!==self.request)return;
            if(!data||!data.ok)throw Error(data&&data.error||'历史读取失败');
            self.data=data;self.selected=Math.max(0,data.points.length-1);
            self.sessionSelect.replaceChildren.apply(self.sessionSelect,[E('option',{value:0},'所有充放电过程')].concat((data.sessions||[]).slice().reverse().map(function(s){
                return E('option',{value:s.segment},modes[s.mode]+' · '+date(s.start)+' → '+date(s.end)+' ('+s.samples+' 条)');
            })));
            self.sessionSelect.value=String(self.segment);
            self.status.textContent=data.summary.samples?'原始 '+data.summary.samples+' 条 · 图中 '+data.points.length+' 条'+(data.downsampled?'（保留极值抽稀）':''):'此区间没有历史记录';
            self.exportButton.disabled=self.exporting||!data.points.length;
            self.paintSummary();self.retention.textContent='现存记录 '+date(data.retained.start)+' — '+date(data.retained.end)+' · 轮转上限 16 MiB，保留天数随日志量变化'+(data.session_count>200?' · 过程列表显示最近 200 段':'')+(data.reader.invalid_lines?' · 跳过 '+data.reader.invalid_lines+' 条不完整或无效记录':'');
            self.draw();self.detail(self.selected);
        }).catch(function(e){if(id===self.request){self.status.textContent=(e.message||'历史读取失败')+(self.data?' · 保留上次结果':'');self.status.classList.add('error');}});
    },
    paintSummary:function(){
        this.status.classList.remove('error');
        var s=this.data.summary,r=s.ranges.controller_v,en=s.energy_estimate;
        function stat(label,value,hint){return E('div',{},[E('span',{},label),E('strong',{},value),E('small',{},hint)]);}
        this.summary.replaceChildren(
            stat('有效连续记录',span(s.covered_s),date(s.start)+' — '+date(s.end)),
            stat('主控电压范围',r?fmt(r.min)+' → '+fmt(r.max)+' V':'—',r?'首尾 '+fmt(r.first)+' → '+fmt(r.last)+' V':'没有有效电压'),
            stat('充入量估算',en.integrated_s?fmt(en.charge_wh)+' Wh':'—',fmt(en.charge_ah)+' Ah · 积分 '+span(en.integrated_s)),
            stat('放出量估算',en.integrated_s?fmt(en.discharge_wh)+' Wh':'—',fmt(en.discharge_ah)+' Ah · 连续片段积分'),
            stat('当前欠压样本',String(s.undervoltage_samples)+' 条','充电 '+span(s.mode_seconds.charge)+' / 放电 '+span(s.mode_seconds.discharge)));
    },
    nearest:function(x){
        var rows=this.data.points;if(!rows.length)return;
        var target=rows[0][0]+Math.max(0,Math.min(1,x))*(rows[rows.length-1][0]-rows[0][0]),best=0;
        rows.forEach(function(r,i){if(Math.abs(r[0]-target)<Math.abs(rows[best][0]-target))best=i;});this.detail(best);this.draw();
    },
    detail:function(index){
        if(!this.data||!this.data.points.length){this.details.textContent='没有可显示的采样；每分钟记录一次，关机期间不产生记录。';return;}
        this.selected=Math.max(0,Math.min(this.data.points.length-1,index));var r=this.data.points[this.selected],m=metrics[this.metric];
        this.details.replaceChildren.apply(this.details,[E('strong',{},date(r[0])+' · '+modes[r[2]]),
            E('span',{},'主控 '+fmt(r[3],3)+' V'),E('span',{},'INA219 '+fmt(r[4],3)+' V'),E('span',{},m.label+' '+fmt(r[m.col],3)+' '+m.unit),
            E('span',{},'电池 '+fmt(r[9],0)+' °C'),E('span',{},r[11]==null?'外电未知':r[11]?'外电接入':'电池供电'),
            E('span',{},r[12]==null?'欠压未知':r[12]?'当前欠压':'无当前欠压')]);
    },
    draw:function(){
        if(!this.data)return;var m=metrics[this.metric];this.flowTitle.textContent=m.label+' · '+m.unit;
        this.plot(this.voltage,[{col:3,color:'#79d9eb',dash:[]},{col:4,color:'#c4b3f8',dash:[6,4]}],'V',false);
        this.plot(this.flow,[{col:m.col,color:m.color,dash:[]}],m.unit,!!m.signed);
    },
    plot:function(canvas,series,unit,signed){
        var width=canvas.clientWidth;if(width<100)return;var height=220,dpr=window.devicePixelRatio||1;
        canvas.width=Math.round(width*dpr);canvas.height=Math.round(height*dpr);var ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);
        var rows=this.data.points,L=48,R=14,T=22,B=height-30,W=width-L-R,H=B-T;
        ctx.font='11px -apple-system,BlinkMacSystemFont,sans-serif';ctx.fillStyle='#9caec2';
        var values=[];rows.forEach(function(r){series.forEach(function(s){if(Number.isFinite(r[s.col]))values.push(r[s.col]);});});
        if(!rows.length||!values.length){ctx.textAlign='center';ctx.fillText('此区间没有有效'+unit+'数据',width/2,height/2);return;}
        var min=Math.min.apply(null,values),max=Math.max.apply(null,values);
        if(signed){min=Math.min(0,min);max=Math.max(0,max);}var pad=Math.max((max-min)*0.12,unit==='V'?0.025:0.1);min-=pad;max+=pad;
        var from=rows[0][0],to=rows[rows.length-1][0];if(from===to){from-=30;to+=30;}
        function x(t){return L+(t-from)/(to-from)*W;}function y(v){return B-(v-min)/(max-min)*H;}
        ctx.lineWidth=1;
        for(var j=0;j<=4;j++){var v=min+(max-min)*j/4,Y=y(v);ctx.strokeStyle='#29384b';ctx.beginPath();ctx.moveTo(L,Y);ctx.lineTo(width-R,Y);ctx.stroke();ctx.fillStyle='#9caec2';ctx.textAlign='right';ctx.fillText(fmt(v,unit==='V'?2:1),L-8,Y+4);}
        if(signed){ctx.strokeStyle='#71849a';ctx.beginPath();ctx.moveTo(L,y(0));ctx.lineTo(width-R,y(0));ctx.stroke();}
        // Shared time scale; background state strips only span continuous samples.
        var colors={charge:'#337d70',discharge:'#896c40',idle:'#3b5673',unknown:'#555e6a'};
        for(var k=1;k<rows.length;k++){if(rows[k][1]===rows[k-1][1]&&rows[k][0]-rows[k-1][0]<=180){ctx.fillStyle=colors[rows[k][2]];ctx.fillRect(x(rows[k-1][0]),4,Math.max(1,x(rows[k][0])-x(rows[k-1][0])),5);}}
        series.forEach(function(s){ctx.strokeStyle=s.color;ctx.fillStyle=s.color;ctx.lineWidth=2;ctx.setLineDash(s.dash);ctx.beginPath();var previous=null;
            rows.forEach(function(r){if(!Number.isFinite(r[s.col])){previous=null;return;}if(!previous||previous[1]!==r[1])ctx.moveTo(x(r[0]),y(r[s.col]));else ctx.lineTo(x(r[0]),y(r[s.col]));previous=r;});ctx.stroke();ctx.setLineDash([]);
            rows.forEach(function(r,i){if(Number.isFinite(r[s.col])&&(rows.length<100||i===0||i===rows.length-1||rows[i-1][1]!==r[1]||rows[i+1][1]!==r[1])){ctx.beginPath();ctx.arc(x(r[0]),y(r[s.col]),2,0,Math.PI*2);ctx.fill();}});
        });
        var ticks=width<450?2:4;
        for(var n=0;n<=ticks;n++){var t=from+(to-from)*n/ticks;ctx.textAlign=n===0?'left':n===ticks?'right':'center';ctx.fillStyle='#9caec2';var d=new Date(t*1000);ctx.fillText((to-from>86400?(d.getMonth()+1)+'/'+d.getDate()+' ':'')+d.toLocaleTimeString('zh-CN',{hour12:false,hour:'2-digit',minute:'2-digit'}),x(t),height-9);}
        var row=rows[this.selected];if(row){ctx.strokeStyle='#657c95';ctx.lineWidth=1;ctx.setLineDash([3,4]);ctx.beginPath();ctx.moveTo(x(row[0]),T);ctx.lineTo(x(row[0]),B);ctx.stroke();ctx.setLineDash([]);series.forEach(function(s){if(Number.isFinite(row[s.col])){ctx.fillStyle=s.color;ctx.beginPath();ctx.arc(x(row[0]),y(row[s.col]),4,0,Math.PI*2);ctx.fill();}});}
        canvas.setAttribute('aria-label',unit+'曲线，'+rows.length+'个采样点，'+date(rows[0][0])+'至'+date(rows[rows.length-1][0])+'。左右方向键查看详情。');
    },
    exportCsv:function(){
        if(!this.data||!this.data.points.length||this.exporting)return;
        var self=this,source=this.data,segment=this.segment,points=[],offset=0,windowId=null;
        this.exporting=true;this.exportButton.disabled=true;this.exportButton.textContent='正在导出…';
        function page(){return read('custom',Math.floor(source.requested.start),Math.floor(source.requested.end),segment,true,offset).then(function(d){
            if(!d||!d.ok)throw Error(d&&d.error||'导出失败');
            if(windowId&&d.window_id!==windowId)throw Error('导出期间日志发生轮转，请刷新后重新导出');
            windowId=d.window_id;points=points.concat(d.points);offset=d.next_offset;
            self.exportButton.textContent='已读取 '+points.length+' 条';
            if(offset!==null)return page();
        });}
        return page().then(function(){self.download(points,source.range);self.status.textContent='已导出 '+points.length+' 条原始记录（未抽稀）';})
            .catch(function(e){self.status.textContent=e.message||'导出失败';self.status.classList.add('error');})
            .finally(function(){self.exporting=false;self.exportButton.disabled=!self.data.points.length;self.exportButton.textContent='导出原始数据 CSV';});
    },
    download:function(points,range){
        var header=['时间 ISO','连续片段','状态','UPS 主控 V','INA219 电池侧 V','电池电流估算 A','电池功率估算 W','Pi 供电 V','Pi 功率估算 W','电池温度估算 C','电量估计 %（未校准）','外电接入','当前欠压'];
        var rows=points.map(function(r){return [new Date(r[0]*1000).toISOString(),r[1],modes[r[2]]].concat(r.slice(3)).map(function(v){return v==null?'':String(v);}).join(',');});
        var blob=new Blob(['\ufeff'+header.join(',')+'\r\n'+rows.join('\r\n')],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),link=E('a',{href:url,download:'KK-Car-battery-'+range+'.csv'});link.click();setTimeout(function(){URL.revokeObjectURL(url);},1000);
    }
});

return baseclass.extend({create:function(){return new HistoryPanel();}});
