'use strict';
// Pure transition engine. Clock and observations are injected for isolated tests.
function step(s,x,c,now) {
    s=s || {};s.rules ||= {};s.last ||= {};s.clients ||= {};
    if(s.seen!=null && now-s.seen>45) for(let key,r in s.rules) {r.candidate=null;r.since=now;}
    s.seen=now;
    let events=[];
    function emit(kind,key,text,recovered) {
        if(!c.enabled || !c.events[kind] || (recovered && !c.events.recovery)) return;
        let id=kind+':'+key+(recovered?':recovery':':alert');
        if(s.last[id]!=null && now-s.last[id]<c.cooldown_seconds) return;
        s.last[id]=now;push(events,{kind,text,at:x.timestamp || 0});
    }
    function transition(key,value,hold,kind,text,recovered,initial_alert) {
        let r=s.rules[key];
        if(value==null) {if(r) {r.candidate=null;r.since=now;}return;}
        if(!r) {s.rules[key]={value:initial_alert?false:value,candidate:value,since:now};return;}
        if(r.candidate!==value) {r.candidate=value;r.since=now;}
        if(value!==r.value && now-r.since>=hold) {r.value=value;emit(kind,key,text,recovered);}
    }
    let v=x.vpn;
    // A tunnel needs two observations; a missing sample is never a disconnect.
    transition('vpn',v,10,v?'vpn_up':'vpn_down',v?'VPN 已上线':'VPN 已下线',false,false);
    if(x.uplink!=null) transition('uplink',x.uplink,10,'uplink','上网出口：'+({ethernet:'有线 WAN',cellular:'4G 上网棒',none:'无可用出口'}[x.uplink] || '未知'),false,false);
    let fresh=x.ping && x.timestamp-x.ping.timestamp>=0 && x.timestamp-x.ping.timestamp<35;
    let good=fresh && v===true && x.ping.sent>0;
    let latency=good && x.ping.avg_ms!=null ? x.ping.avg_ms : null;
    let lr=s.rules.latency?.value;
    let high=latency==null ? null : latency >= c.latency_ms ? true : latency < c.latency_ms*0.8 ? false : lr || false;
    transition('latency',high,c.hold_seconds,'latency',high?'VPN 延迟持续过高：'+int(latency)+' ms':'VPN 延迟已恢复',!high,true);
    let loss=good ? x.ping.loss_percent : null;
    let lossHigh=loss==null ? null : loss>=c.loss_percent ? true : loss<c.loss_percent/2 ? false : s.rules.loss?.value || false;
    transition('loss',lossHigh,c.hold_seconds,'loss',lossHigh?'VPN 持续丢包：'+int(loss)+'%':'VPN 丢包已恢复',!lossHigh,true);
    let signal=x.rsrp;
    let weak=signal==null ? null : signal<=c.signal_dbm ? true : signal>=c.signal_dbm+5 ? false : s.rules.signal?.value || false;
    transition('signal',weak,max(60,c.hold_seconds),'signal',weak?'蜂窝信号持续偏弱：'+signal+' dBm':'蜂窝信号已恢复',!weak,true);
    let hot=x.temperature==null ? null : x.temperature>=c.temperature_c ? true : x.temperature<=c.temperature_c-5 ? false : s.rules.temperature?.value || false;
    transition('temperature',hot,c.hold_seconds,'temperature',hot?'树莓派持续高温：'+x.temperature+' °C':'树莓派温度已恢复',!hot,true);
    transition('power',x.undervoltage,10,'power',x.undervoltage?'树莓派当前供电不足':'树莓派供电已恢复',!x.undervoltage,true);
    if(x.clients!=null) {
        for(let mac,name in x.clients) {
            let p=s.clients[mac];
            if(!p) {p={online:true,last:now};s.clients[mac]=p;if(s.clients_ready)emit('client_join','join:'+mac,'设备接入：'+name,false);}
            else if(!p.online) {p.online=true;emit('client_join','join:'+mac,'设备重新接入：'+name,false);}
            p.last=now;p.name=name;
        }
        for(let mac,p in s.clients) {
            if(p.online && now-p.last>=120) {p.online=false;emit('client_leave','leave:'+mac,'设备离线（观察到 2 分钟无连接）：'+p.name,false);}
            if(!p.online && now-p.last>86400) {delete s.clients[mac];delete s.last['client_join:join:'+mac+':alert'];delete s.last['client_leave:leave:'+mac+':alert'];}
        }
        s.clients_ready=true;
    }
    return {state:s,events};
}
export {step};
