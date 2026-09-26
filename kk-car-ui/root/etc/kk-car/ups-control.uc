'use strict';
import { readfile, writefile, rename, chmod, mkdir, rmdir, popen } from 'fs';
import { sample } from '/etc/kk-car/ups-read.uc';
import { record_event } from '/etc/kk-car/diagnostic-event.uc';

const POLICY='/etc/kk-car/private/ups-policy.json';
const LOCK='/tmp/kk-car-ups-write-lock';

function locked(fn) {
    if (!mkdir(LOCK,0700)) return {ok:false,error:'另一项 UPS 操作正在进行'};
    let result;
    try { result=fn(); }
    catch(e) { result={ok:false,error:'UPS 操作异常，未能确认结果'}; }
    rmdir(LOCK);
    return result;
}

function policy() {
    let raw=readfile(POLICY), data={};
    try { data=json(raw || '{}'); } catch(e) {}
    return {enabled:data.enabled===true,shutdown_mv:type(data.shutdown_mv)=='int' &&
        data.shutdown_mv>=3300 && data.shutdown_mv<=3900 ? data.shutdown_mv : 3550};
}

function save_policy(enabled,shutdown_mv) {
    if (type(enabled)!='bool' || type(shutdown_mv)!='int' || shutdown_mv<3300 || shutdown_mv>3900)
        return {ok:false,error:'低电阈值须为 3300–3900 mV'};
    let before=policy(), next={enabled,shutdown_mv};
    if (before.enabled==enabled && before.shutdown_mv==shutdown_mv) return {ok:true,unchanged:true,policy:before};
    let path=POLICY+'.new';
    if (!writefile(path,sprintf('%J',next))) return {ok:false,error:'无法保存低电策略'};
    chmod(path,0600);
    if (!rename(path,POLICY)) return {ok:false,error:'无法完成低电策略保存'};
    return {ok:true,policy:policy()};
}

function write_reg(reg,value) {
    return system(sprintf('/usr/sbin/i2cset -y 1 0x17 %d %d b >/dev/null 2>&1',reg,value))==0;
}

function write_u16(reg,value) {
    return write_reg(reg,value&255) && write_reg(reg+1,(value>>8)&255);
}

function field(data,key) {
    let b=data.battery || {},c=data.controller || {};
    if (key=='sample_minutes') return c.sample_minutes;
    if (key=='auto_start_on_ac') return c.auto_start_on_ac?1:0;
    if (key=='full_mv') return b.configured_full_mv;
    if (key=='empty_mv') return b.configured_empty_mv;
    if (key=='protect_mv') return b.configured_protect_mv;
    if (key=='user_programmed') return b.user_programmed?1:0;
    return null;
}

function battery_voltage_error(key,value,b) {
    if (key=='full_mv' && value<=b.configured_protect_mv+100)
        return '满电基准必须高于保护电压至少 100 mV';
    if (key=='empty_mv' && b.configured_protect_mv &&
        (value>b.configured_protect_mv || b.user_programmed && value==b.configured_protect_mv))
        return '自动模式空电基准可等于保护电压；手动模式必须低于保护电压';
    if (key=='protect_mv' && (value>=b.configured_full_mv-100 || value<b.configured_empty_mv ||
        b.user_programmed && value==b.configured_empty_mv))
        return '保护电压须低于满电基准；手动模式须高于空电基准';
    // Vendor V9 clamps the measured voltage to the empty value in manual mode
    // before its protection comparison. Equal limits are only allowed in auto mode.
    if (key=='user_programmed' && value==1 &&
        (b.configured_empty_mv<2500 || b.configured_protect_mv<2750 ||
         b.configured_empty_mv>=b.configured_protect_mv || b.configured_protect_mv>=b.configured_full_mv-100))
        return '先核对电压关系；手动模式空电基准必须低于保护电压';
    return null;
}

function set_option(key,value,expected,confirm) {
    let regs={sample_minutes:0x15,auto_start_on_ac:0x19,full_mv:0x0d,
        empty_mv:0x0f,protect_mv:0x11,user_programmed:0x2a};
    if (regs[key]==null || type(value)!='int' || type(expected)!='int')
        return {ok:false,error:'不支持的设置或数值格式错误'};
    let battery=key=='full_mv'||key=='empty_mv'||key=='protect_mv'||key=='user_programmed';
    if (key=='sample_minutes' && (value<1||value>1440) ||
        (key=='auto_start_on_ac'||key=='user_programmed') && value!=0 && value!=1 ||
        key=='full_mv' && (value<4000||value>4500) ||
        key=='empty_mv' && (value<2500||value>3900) ||
        key=='protect_mv' && (value<2750||value>3900))
        return {ok:false,error:'设置值超出设备允许的安全范围'};
    if (battery && confirm!='修改电池参数')
        return {ok:false,error:'电池参数需要明确确认'};
    return locked(function() {
        let before=sample();
        if (!before.ok) return {ok:false,error:'UPS 当前无法读取，未写入'};
        let old=field(before,key);
        if (old!==expected) return {ok:false,error:'设备上的设置已变化，请刷新页面后再操作',current:old};
        if (value==old) return {ok:true,unchanged:true,status:before};
        if (battery && !before.input.external) return {ok:false,error:'修改电池参数必须保持外部供电'};
        let b=before.battery;
        let invalid=battery_voltage_error(key,value,b);
        if (invalid) return {ok:false,error:invalid};
        let reg=regs[key], ok=(key=='auto_start_on_ac'||key=='user_programmed') ?
            write_reg(reg,value) : write_u16(reg,value);
        let after=sample();
        if (!ok || !after.ok || field(after,key)!=value) {
            if (old!=null) {
                if (key=='auto_start_on_ac'||key=='user_programmed') write_reg(reg,old);
                else write_u16(reg,old);
            }
            return {ok:false,error:'写入后校验失败，已尝试恢复原值'};
        }
        return {ok:true,status:after};
    });
}

function rtc_sync() {
    return locked(function() {
        let current=sample();
        if (!current.ok || !current.sensors.rtc.detected) return {ok:false,error:'RTC 未连接'};
        let p=popen('/bin/date -u +%Y%m%d%H%M%S%u');
        if (!p) return {ok:false,error:'无法读取系统时间'};
        let stamp=trim(p.read('all') || '');p.close();
        let m=match(stamp,/^(20\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)([1-7])$/);
        if (!m || +m[1]<2024 || +m[1]>2099) return {ok:false,error:'系统时间未校准，不能写入 RTC'};
        let bcd=(v)=>int(v/10)*16+v%10;
        let values=[+m[6],+m[5],+m[4],+m[7],+m[3],+m[2],(+m[1])%100];
        let cmd='/usr/sbin/i2ctransfer -y 1 w8@0x68 0x00';
        for (let v in values) cmd+=sprintf(' 0x%02x',bcd(v));
        if (system(cmd+' >/dev/null 2>&1')!=0) return {ok:false,error:'RTC 写入失败'};
        let checked=sample();
        if (!checked.ok) return {ok:false,error:'RTC 写入后无法读取 UPS 状态'};
        let after=checked.sensors.rtc;
        if (!after?.valid) return {ok:false,error:'RTC 写入后仍未运行'};
        return {ok:true,rtc:after};
    });
}

function power_action(action,confirm) {
    let phrases={shutdown:'关闭树莓派',restart_ups:'重启UPS',reboot_pi:'重启树莓派',
        factory_reset:'恢复出厂'};
    if (action=='cancel_shutdown'||action=='cancel_restart') {
        return locked(function() {
            let reg=action=='cancel_shutdown'?0x18:0x1a;
            if (!write_reg(reg,0)) return {ok:false,error:'取消倒计时失败'};
            let after=sample(), left=action=='cancel_shutdown'?after.controller?.shutdown_countdown_s:after.controller?.restart_countdown_s;
            let ok=after.ok && left==0;
            record_event(ok?'power_action':'power_action_failed',{action});
            return ok?{ok:true,status:after}:{ok:false,error:'取消后读回未确认'};
        });
    }
    if (!phrases[action] || confirm!=phrases[action]) return {ok:false,error:'操作确认文字不匹配'};
    return locked(function() {
        let before=sample();
        if (!before.ok) return {ok:false,error:'UPS 当前无法读取'};
        record_event('power_action',{action,external:before.input?.external,
            controller_mv:before.battery?.millivolts,sensor_mv:before.sensors?.battery?.bus_mv});
        if (action=='factory_reset') {
            if (!before.input.external) return {ok:false,error:'恢复出厂必须连接外部电源'};
            let backup='/etc/kk-car/private/ups-settings-before-reset.json';
            if (!writefile(backup,sprintf('%J',{at:time(),battery:before.battery,controller:before.controller})))
                return {ok:false,error:'无法备份现有参数'};
            chmod(backup,0600);
            if (!write_reg(0x1b,1)) return {ok:false,error:'恢复出厂指令失败'};
            return {ok:true,accepted:true};
        }
        if (action=='shutdown'||action=='restart_ups') {
            let reg=action=='shutdown'?0x18:0x1a;
            if (!write_reg(reg,180)) {
                record_event('power_action_failed',{action});
                return {ok:false,error:'无法设置 UPS 断电倒计时'};
            }
            let after=sample();
            let left=action=='shutdown'?after.controller?.shutdown_countdown_s:after.controller?.restart_countdown_s;
            if (left==null || left<170 || left>180) {
                write_reg(reg,0);
                record_event('power_action_failed',{action});
                return {ok:false,error:'UPS 倒计时未确认，已尝试取消'};
            }
        }
        // The response reaches the browser before the operating system stops.
        writefile('/tmp/kk-car-power-intent.json',sprintf('%J',{timestamp:time(),action}));
        chmod('/tmp/kk-car-power-intent.json',0600);
        system('(/bin/sleep 2; /bin/sync; /sbin/'+(action=='reboot_pi'?'reboot':'poweroff')+') </dev/null >/dev/null 2>&1 &');
        return {ok:true,accepted:true};
    });
}

export { policy,save_policy,set_option,battery_voltage_error,rtc_sync,power_action };
