'use strict';
import { access, popen } from 'fs';

// EP-0136 UPS Plus. This module only reads documented registers.
function command(cmd) {
    let p = popen(cmd + ' 2>/dev/null');
    if (!p) return null;
    let output = p.read('all');
    let rc = p.close();
    return rc == 0 ? trim(output || '') : null;
}

function sample() {
    let result = {ok:false, timestamp:time(), model:'52Pi UPS Plus EP-0136',
        interface:'i2c-1', warnings:[]};
    if (!access('/dev/i2c-1')) {
        result.error='I²C 接口未启用或设备未就绪';
        return result;
    }
    let raw = command('/usr/sbin/i2ctransfer -y 1 w1@0x17 0x01 r42');
    if (raw == null) {
        result.error='UPS 主控未响应（0x17）';
        return result;
    }
    let parts = split(raw, /\s+/), bytes=[];
    if (length(parts) != 42) {
        result.error='UPS 返回的数据长度不正确';
        return result;
    }
    for (let part in parts) {
        if (!match(part, /^0x[0-9a-fA-F]{2}$/)) {
            result.error='UPS 返回了无法解析的数据';
            return result;
        }
        push(bytes, int(part,16));
    }
    function u16(reg) { let i=reg-1; return bytes[i] + 256*bytes[i+1]; }
    function u32(reg) { let i=reg-1; return bytes[i] + 256*bytes[i+1] +
        65536*bytes[i+2] + 16777216*bytes[i+3]; }
    let temp=u16(0x0b);
    if (temp>=32768) temp-=65536;
    let charge=u16(0x13), pogo=u16(0x03), battery=u16(0x05);
    let usbC=u16(0x07), micro=u16(0x09), full=u16(0x0d), empty=u16(0x0f);
    let mode=bytes[0x17-1], interval=u16(0x15), version=u16(0x28);
    if (pogo>5500 || battery>4500 || usbC>13500 || micro>13500 ||
        temp< -20 || temp>100 || charge>100 || interval<1 || interval>1440 ||
        (mode!=0 && mode!=1) || version<1) {
        result.error='UPS 数值超出合理范围；已隐藏本次读数';
        return result;
    }
    let power=command('/usr/bin/vcgencmd get_throttled');
    let bits=match(power || '', /0x([0-9a-fA-F]+)/);
    let throttled=bits ? int(bits[1],16) : null;
    let external=usbC>=4400 || micro>=4400;
    result.ok=true;
    result.battery={percent:charge, millivolts:battery, temperature_c:temp,
        configured_full_mv:full, configured_empty_mv:empty,
        percent_calibration_required:true};
    result.input={external, usb_c_mv:usbC, micro_usb_mv:micro};
    result.output={pogo_mv:pogo, mcu_mv:u16(0x01),
        pi_undervoltage:throttled==null ? null : !!(throttled&1),
        pi_undervoltage_history:throttled==null ? null : !!(throttled&0x10000),
        pi_throttled:throttled==null ? null : !!(throttled&4)};
    result.controller={version, powered:mode==1, sample_minutes:interval,
        auto_start_on_ac:bytes[0x19-1]==1,
        shutdown_countdown_s:bytes[0x18-1], restart_countdown_s:bytes[0x1a-1],
        total_run_s:u32(0x1c), charging_s:u32(0x20), current_run_s:u32(0x24)};
    result.sensors={pi_supply:access('/sys/bus/i2c/devices/1-0040') || !!command('/usr/sbin/i2ctransfer -y 1 w1@0x40 0x00 r2'),
        battery:access('/sys/bus/i2c/devices/1-0045') || !!command('/usr/sbin/i2ctransfer -y 1 w1@0x45 0x00 r2'),
        rtc:access('/sys/bus/i2c/devices/1-0068') || !!command('/usr/sbin/i2ctransfer -y 1 w1@0x68 0x00 r1')};
    if (!external) push(result.warnings,'外部输入已断开，正在使用电池');
    if (temp>=50) push(result.warnings,'电池温度偏高，请检查散热和充电环境');
    if (pogo<4700) push(result.warnings,'树莓派供电电压偏低');
    if (throttled!=null && (throttled&1)) push(result.warnings,'树莓派当前报告欠压');
    if (charge<=20) push(result.warnings,'电量估计值偏低；尚需完整充放电校准');
    return result;
}

export { sample };
