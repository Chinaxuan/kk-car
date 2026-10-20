'use strict';
import { readfile, writefile, rename, chmod, mkdir, rmdir, popen } from 'fs';
import { sample } from '/etc/kk-car/ups-read.uc';
import { record_event } from '/etc/kk-car/diagnostic-event.uc';
import { connect } from 'ubus';

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
        data.shutdown_mv>=3300 && data.shutdown_mv<=3900 ? data.shutdown_mv : 3550,
        mode:data.mode=='percent'?'percent':'voltage',
        shutdown_percent:type(data.shutdown_percent)=='int' && data.shutdown_percent>=5 &&
            data.shutdown_percent<=30 ? data.shutdown_percent : 10,
        emergency_mv:type(data.emergency_mv)=='int' && data.emergency_mv>=3100 &&
            data.emergency_mv<=3500 ? data.emergency_mv : 3250,
        idle_enabled:data.idle_enabled===true,
        idle_minutes:type(data.idle_minutes)=='int' && data.idle_minutes>=5 &&
            data.idle_minutes<=240 ? data.idle_minutes : 60};
}

function write_policy(next) {
    let path=POLICY+'.new';
    if (!writefile(path,sprintf('%J',next))) return {ok:false,error:'无法保存关机策略'};
    chmod(path,0600);
    if (!rename(path,POLICY)) return {ok:false,error:'无法完成关机策略保存'};
    return {ok:true,policy:policy()};
}

function save_policy(enabled,shutdown_mv) {
    if (type(enabled)!='bool' || type(shutdown_mv)!='int' || shutdown_mv<3300 || shutdown_mv>3900)
        return {ok:false,error:'低电阈值须为 3300–3900 mV'};
    let before=policy(), next={...before,enabled,shutdown_mv,mode:'voltage'};
    if (before.enabled==enabled && before.shutdown_mv==shutdown_mv && before.mode=='voltage')
        return {ok:true,unchanged:true,policy:before};
    return write_policy(next);
}

function save_shutdown_policy(enabled,mode,shutdown_mv,shutdown_percent,emergency_mv) {
    if (type(enabled)!='bool' || (mode!='voltage' && mode!='percent') ||
        type(shutdown_mv)!='int' || shutdown_mv<3300 || shutdown_mv>3900 ||
        type(shutdown_percent)!='int' || shutdown_percent<5 || shutdown_percent>30 ||
        type(emergency_mv)!='int' || emergency_mv<3100 || emergency_mv>3500)
        return {ok:false,error:'关机参数超出允许范围'};
    let before=policy(),next={...before,enabled,mode,shutdown_mv,
        shutdown_percent,emergency_mv};
    if (before.enabled==enabled && before.mode==mode && before.shutdown_mv==shutdown_mv &&
        before.shutdown_percent==shutdown_percent && before.emergency_mv==emergency_mv)
        return {ok:true,unchanged:true,policy:before};
    return write_policy(next);
}

function save_idle_policy(idle_enabled,idle_minutes) {
    if (type(idle_enabled)!='bool' || type(idle_minutes)!='int' ||
        idle_minutes<5 || idle_minutes>240)
        return {ok:false,error:'无人连接关机时间须为 5–240 分钟'};
    let before=policy(), next={...before,idle_enabled,idle_minutes};
    if (before.idle_enabled==idle_enabled && before.idle_minutes==idle_minutes)
        return {ok:true,unchanged:true,policy:before};
    return write_policy(next);
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

function battery_settings(data) {
    let b=data.battery || {};
    return {full_mv:b.configured_full_mv,empty_mv:b.configured_empty_mv,
        protect_mv:b.configured_protect_mv,manual:b.user_programmed===true};
}

function battery_revision(v) {
    return sprintf('%d:%d:%d:%d',v.full_mv,v.empty_mv,v.protect_mv,v.manual?1:0);
}

function battery_expected_matches(old,expected) {
    let parts=split(expected,':');
    return old.protect_mv==+parts[2] && (old.manual?1:0)==+parts[3] &&
        (!old.manual || battery_revision(old)==expected);
}

function battery_settings_error(v) {
    if (type(v.full_mv)!='int' || type(v.empty_mv)!='int' ||
        type(v.protect_mv)!='int' || type(v.manual)!='bool') return '请输入整数电压和有效参数模式';
    if (v.protect_mv<2750 || v.protect_mv>3900) return '保护电压须为 2750–3900 mV';
    // Learned full/empty values are not writable targets when returning to auto.
    if (!v.manual) return null;
    if (v.full_mv<4000 || v.full_mv>4500 || v.empty_mv<2500 || v.empty_mv>3900)
        return '满电基准须为 4000–4500 mV，空电基准须为 2500–3900 mV';
    if (v.empty_mv>=v.protect_mv || v.protect_mv>=v.full_mv-100)
        return '手动模式需要：空电基准 < 保护电压 < 满电基准 − 100 mV';
    return null;
}

function battery_matches(a,b) {
    return a.manual==b.manual && a.protect_mv==b.protect_mv &&
        (!b.manual || a.full_mv==b.full_mv && a.empty_mv==b.empty_mv);
}

// Injectable I/O allows failure and firmware-learning cases to be tested without
// accessing the actual battery. The application lock spans the entire sequence.
function battery_transaction(next,before,io) {
    let old=battery_settings(before), after;
    function apply(v) {
        if (v.manual) {
            // The vendor firmware ignores full/empty writes in auto mode. Give
            // it time to adopt manual mode before writing all six voltage bytes.
            if (!io.mode(1)) return false;
            io.wait();
            return io.voltages(v);
        }
        return io.protection(v.protect_mv) && io.mode(0);
    }
    function verified(v) {
        for (let n=0;n<2;n++) {
            io.wait();after=io.read();
            if (!after.ok || !battery_matches(battery_settings(after),v)) return false;
        }
        return true;
    }
    let applied=false;
    try {applied=apply(next) && verified(next);} catch(e) {}
    if (applied) return {ok:true,status:after,settings:battery_settings(after)};
    let restored=false;
    try {
        // Restore baselines before restoring automatic mode. Auto can then
        // legitimately relearn them; only its mode/protection are fixed targets.
        let restore={...old,manual:true};
        restored=apply(restore) && (old.manual || io.mode(0)) && verified(old);
    } catch(e) {}
    return {ok:false,rollback_verified:restored,
        error:restored?'电池参数读回不一致，已恢复原参数模式及保护电压；你的输入已保留':
            '电池参数写入失败，恢复未能确认；请保持外部供电并重新读取设备',
        status:after};
}

function save_battery(full_mv,empty_mv,protect_mv,manual,expected,confirm) {
    let next={full_mv,empty_mv,protect_mv,manual};
    let invalid=battery_settings_error(next);
    if (invalid) return {ok:false,error:invalid};
    if (type(expected)!='string' || !match(expected,/^\d+:\d+:\d+:[01]$/))
        return {ok:false,error:'设备参数版本无效，请重新读取'};
    if (confirm!='修改电池参数') return {ok:false,error:'电池参数需要明确确认'};
    return locked(function() {
        let before=sample();
        if (!before.ok) return {ok:false,error:'UPS 当前无法读取，未写入'};
        let old=battery_settings(before);
        // Full/empty are volatile in automatic learning mode, not concurrent edits.
        if (!battery_expected_matches(old,expected))
            return {ok:false,error:'设备参数已被其他操作修改，请先重新读取；你的输入已保留',settings:old};
        if (!before.input.external) return {ok:false,error:'修改电池参数必须保持外部供电'};
        if (before.controller.shutdown_countdown_s || before.controller.restart_countdown_s)
            return {ok:false,error:'UPS 电源倒计时正在运行，未修改电池参数'};
        if (battery_matches(old,next)) return {ok:true,unchanged:true,status:before,settings:old};
        let backup='/etc/kk-car/private/ups-battery-before-save.json';
        if (!writefile(backup,sprintf('%J',{timestamp:time(),settings:old})))
            return {ok:false,error:'无法保存原电池参数，未写入'};
        chmod(backup,0600);
        let result=battery_transaction(next,before,{
            mode:(v)=>write_reg(0x2a,v),
            protection:(v)=>write_u16(0x11,v),
            voltages:function(v) {
                // One bus transfer prevents the firmware observing half-written
                // 16-bit values between separate i2cset processes.
                return system(sprintf('/usr/sbin/i2ctransfer -y 1 w7@0x17 0x0d %d %d %d %d %d %d >/dev/null 2>&1',
                    v.full_mv&255,v.full_mv>>8,v.empty_mv&255,v.empty_mv>>8,
                    v.protect_mv&255,v.protect_mv>>8))==0;
            },
            wait:function() {system('/bin/sleep 0.2');},read:()=>sample()
        });
        record_event(result.ok?'battery_settings_saved':'battery_settings_failed',
            {before:old,requested:next,after:result.settings,rollback_verified:result.rollback_verified});
        return result;
    });
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
        if (key=='auto_start_on_ac' && value==1 &&
            (before.controller.shutdown_countdown_s || before.controller.restart_countdown_s ||
             readfile('/tmp/kk-car-power-intent.json')))
            return {ok:false,error:'关机或重启任务已提交，不能开启来电自启'};
        let old=field(before,key);
        if (old!==expected) return {ok:false,error:'设备上的设置已变化，请刷新页面后再操作',current:old};
        if (value==old) return {ok:true,unchanged:true,status:before};
        if (battery && !before.input.external) return {ok:false,error:'修改电池参数必须保持外部供电'};
        let b=before.battery;
        if ((key=='full_mv'||key=='empty_mv') && !b.user_programmed)
            return {ok:false,error:'自动学习模式会覆盖电池基准，请用整组电池参数保存并启用手动模式'};
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

// Only runs during an explicit power action. Injected I/O keeps tests away from
// the I2C bus and the real watchdog. Never extend an inherited cutoff timer.
function prepare_shutdown(io) {
    let before=io.read();
    if (!before?.ok) return {ok:false,stage:'read',error:'UPS 当前无法读取'};
    let existing=before.controller?.shutdown_countdown_s || 0;
    if (!io.write(0x19,0)) return {ok:false,stage:'auto_start',error:'无法关闭来电自启，未提交关机'};
    if (!io.write(0x1a,0)) return {ok:false,stage:'restart_timer',error:'无法清除 UPS 重启倒计时'};
    if (!existing && !io.write(0x18,180))
        return {ok:false,stage:'cutoff_timer',error:'无法设置 UPS 断电倒计时'};
    let after=io.read(),c=after?.controller;
    if (!after?.ok || c?.auto_start_on_ac!==false || c.restart_countdown_s!=0 ||
        !(c.shutdown_countdown_s>0 && c.shutdown_countdown_s<=(existing || 180)) ||
        (!existing && c.shutdown_countdown_s<170))
        return {ok:false,stage:'readback',error:'断电准备未通过读回核对；不会取消已有断电任务'};
    let watchdog;
    try {watchdog=io.stop_watchdog();} catch(e) {watchdog={ok:false};}
    // Keep a confirmed hardware cutoff even if the OS watchdog cannot be
    // stopped; returning to a running low battery would be less safe.
    return {ok:true,stage:'armed',shutdown_s:c.shutdown_countdown_s,
        preserved:existing>0,auto_start_disabled:true,restart_cancelled:true,
        watchdog_stopped:watchdog?.ok===true};
}

function stop_shutdown_watchdog() {
    try {
        let bus=connect(),before=bus.call('system','watchdog',{});
        if (before?.status=='offline') return {ok:true};
        if (!before || index(['running','stopped'],before.status)<0) return {ok:false};
        bus.call('system','watchdog',{magicclose:true,stop:true});
        let checked=bus.call('system','watchdog',{});
        // procd reports offline after successfully closing the watchdog FD.
        return {ok:checked && index(['offline','stopped'],checked.status)>=0 &&
            checked.magicclose===true};
    } catch(e) {return {ok:false};}
}

function power_action(action,confirm) {
    let phrases={shutdown:'关闭树莓派',restart_ups:'重启UPS',reboot_pi:'重启树莓派',
        factory_reset:'恢复出厂'};
    if (action=='cancel_shutdown'||action=='cancel_restart') {
        return locked(function() {
            if (readfile('/tmp/kk-car-power-intent.json'))
                return {ok:false,error:'系统关机已经提交，保留断电倒计时；不能只取消硬件断电'};
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
        let prepared=null;
        if (action=='shutdown') {
            prepared=prepare_shutdown({read:()=>sample(),write:write_reg,
                stop_watchdog:stop_shutdown_watchdog});
            record_event(prepared.ok?'ups_cutoff_armed':'power_action_failed',
                {action,stage:prepared.stage,shutdown_s:prepared.shutdown_s,
                auto_start_disabled:prepared.auto_start_disabled,
                restart_cancelled:prepared.restart_cancelled,
                watchdog_stopped:prepared.watchdog_stopped,preserved:prepared.preserved});
            if (!prepared.ok) return prepared;
        }
        if (action=='restart_ups') {
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
        let intent={timestamp:time(),action,shutdown:prepared};
        writefile('/tmp/kk-car-power-intent.json',sprintf('%J',intent));
        chmod('/tmp/kk-car-power-intent.json',0600);
        // Keep the last verified sequence after reboot. No battery identities,
        // addresses or arbitrary command text are stored here.
        if (writefile('/etc/kk-car/private/ups-power-intent.json.new',sprintf('%J',intent))) {
            chmod('/etc/kk-car/private/ups-power-intent.json.new',0600);
            rename('/etc/kk-car/private/ups-power-intent.json.new','/etc/kk-car/private/ups-power-intent.json');
        }
        system('(/bin/sleep 2; /bin/sync; /sbin/'+(action=='reboot_pi'?'reboot':'poweroff')+') </dev/null >/dev/null 2>&1 &');
        return {ok:true,accepted:true,shutdown:prepared};
    });
}

export { policy,save_policy,save_shutdown_policy,save_idle_policy,set_option,battery_voltage_error,battery_settings,
    battery_revision,battery_expected_matches,battery_settings_error,battery_transaction,save_battery,rtc_sync,
    prepare_shutdown,power_action };
