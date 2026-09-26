'use strict';
import { access, popen, readfile } from 'fs';

// EP-0136 UPS Plus. This module only reads documented registers.
function command(cmd) {
    let p = popen(cmd + ' 2>/dev/null');
    if (!p) return null;
    let output = p.read('all');
    let rc = p.close();
    return rc == 0 ? trim(output || '') : null;
}

function bytes(cmd,count) {
    let raw=command(cmd);
    if (raw==null) return null;
    let parts=split(raw,/\s+/), values=[];
    if (length(parts)!=count) return null;
    for (let part in parts) {
        if (!match(part,/^0x[0-9a-fA-F]{2}$/)) return null;
        push(values,int(part,16));
    }
    return values;
}

function ina219(addr,ohms) {
    let base='/usr/sbin/i2ctransfer -y 1 w1@'+addr+' ';
    let config=bytes(base+'0x00 r2',2), shunt=bytes(base+'0x01 r2',2);
    let bus=bytes(base+'0x02 r2',2), calibration=bytes(base+'0x05 r2',2);
    if (!config || !shunt || !bus || !calibration) return {detected:false};
    let word=(b)=>b[0]*256+b[1];
    let shunt_raw=word(shunt), bus_raw=word(bus);
    if (shunt_raw>=32768) shunt_raw-=65536;
    let shunt_uv=shunt_raw*10, bus_mv=(bus_raw>>3)*4;
    // INA219's current/power registers are zero until calibrated. Derive estimates
    // from its raw shunt voltage and the resistor values in the vendor's code.
    let current_ma=shunt_uv/ohms/1000;
    return {detected:true,bus_mv,shunt_uv,current_ma,power_mw:bus_mv*current_ma/1000,
        calibration:word(calibration),config:word(config),conversion_ready:!!(bus_raw&2),overflow:!!(bus_raw&1),
        shunt_ohms:ohms,estimated:true};
}

function voltage_reference(data) {
    function valid(v) { return (type(v)=='int' || type(v)=='double') && v>=2500 && v<=4500; }
    let reported=data?.battery?.millivolts;
    let controller_mv=valid(reported)?reported:null;
    let sensor=data?.sensors?.battery;
    let sensor_mv=sensor?.detected && sensor.conversion_ready && !sensor.overflow &&
        valid(sensor.bus_mv)?sensor.bus_mv:null;
    let difference_mv=null;
    if (controller_mv!=null && sensor_mv!=null) {
        difference_mv=controller_mv-sensor_mv;
        if (difference_mv<0) difference_mv=-difference_mv;
    }
    // A consistency check, not a calibrated correction or a discharge endpoint.
    // Preserve both raw readings; never invent an offset from one measurement.
    let sensor_rejected=difference_mv!=null && difference_mv>150;
    let use_sensor=sensor_mv!=null && !sensor_rejected;
    return {millivolts:use_sensor?sensor_mv:controller_mv,
        source:use_sensor?'battery_sensor':controller_mv!=null?'controller':null,
        controller_mv,sensor_mv,difference_mv,sensor_rejected,calibration_verified:false};
}

function bcd(v) { return (v>>4)*10+(v&15); }
function rtc() {
    let raw=bytes('/usr/sbin/i2ctransfer -y 1 w1@0x68 0x00 r7',7);
    if (!raw) return {detected:false};
    let halted=!!(raw[0]&0x80);
    let hour=(raw[2]&0x40) ? bcd(raw[2]&0x1f)%12+(raw[2]&0x20?12:0) : bcd(raw[2]&0x3f);
    let second=bcd(raw[0]&0x7f),minute=bcd(raw[1]&0x7f);
    let day=bcd(raw[4]&0x3f),month=bcd(raw[5]&0x1f),year=2000+bcd(raw[6]);
    let valid=!halted && year>=2020 && month>=1 && month<=12 && day>=1 && day<=31 &&
        hour<=23 && minute<=59 && second<=59;
    let stamp=valid?sprintf('%04d-%02d-%02d %02d:%02d:%02d',year,month,day,hour,minute,second):null;
    return {detected:true,halted,valid,time_register:stamp};
}

function validRaw(v) {
    if (!v || length(v)!=42) return false;
    let u16=(reg)=>v[reg-1]+256*v[reg];
    let u32=(reg)=>u16(reg)+65536*u16(reg+2);
    let temperature=u16(0x0b);
    if (temperature>=32768) temperature-=65536;
    let total=u32(0x1c),charging=u32(0x20),current=u32(0x24);
    return u16(0x01)>=2400 && u16(0x01)<=3600 &&
        u16(0x03)<=5500 && u16(0x05)<=4500 &&
        u16(0x07)<=13500 && u16(0x09)<=13500 &&
        temperature>=-20 && temperature<=100 &&
        u16(0x0d)<=4500 && u16(0x0f)<=4500 && u16(0x11)<=4500 &&
        u16(0x13)<=100 && u16(0x15)>=1 && u16(0x15)<=1440 &&
        (v[0x17-1]==0 || v[0x17-1]==1) &&
        u16(0x28)>=1 && u16(0x28)<=255 &&
        total<=2147483647 && charging<=2147483647 && current<=2147483647 &&
        current<=total+120 && charging<=total+86400;
}

function sample(lite,attempt) {
    let result = {ok:false, timestamp:time(), model:'52Pi UPS Plus EP-0136',
        interface:'i2c-1', warnings:[]};
    if (!access('/dev/i2c-1')) {
        result.error='I²C 接口未启用或设备未就绪';
        return result;
    }
    let values = bytes('/usr/sbin/i2ctransfer -y 1 w1@0x17 0x01 r42',42);
    if (values == null) {
        if ((attempt || 0)<2) return sample(lite,(attempt || 0)+1);
        result.error='UPS 主控未响应（0x17）';
        return result;
    }
    function u16(reg) { let i=reg-1; return values[i] + 256*values[i+1]; }
    function u32(reg) { let i=reg-1; return values[i] + 256*values[i+1] +
        65536*values[i+2] + 16777216*values[i+3]; }
    let temp=u16(0x0b);
    if (temp>=32768) temp-=65536;
    let charge=u16(0x13), pogo=u16(0x03), battery=u16(0x05);
    let usbC=u16(0x07), micro=u16(0x09), full=u16(0x0d), empty=u16(0x0f);
    let mode=values[0x17-1], interval=u16(0x15), version=u16(0x28);
    if (!validRaw(values)) {
        if ((attempt || 0)<2) return sample(lite,(attempt || 0)+1);
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
        configured_protect_mv:u16(0x11),user_programmed:values[0x2a-1]==1,
        percent_calibration_unverified:true};
    result.input={external, usb_c_mv:usbC, micro_usb_mv:micro};
    result.output={pogo_mv:pogo, mcu_mv:u16(0x01),
        pi_undervoltage:throttled==null ? null : !!(throttled&1),
        pi_frequency_capped:throttled==null ? null : !!(throttled&2),
        pi_frequency_capped_history:throttled==null ? null : !!(throttled&0x20000),
        pi_undervoltage_history:throttled==null ? null : !!(throttled&0x10000),
        pi_throttled:throttled==null ? null : !!(throttled&4),
        pi_throttled_history:throttled==null ? null : !!(throttled&0x40000),
        pi_soft_temp_limit:throttled==null ? null : !!(throttled&8),
        pi_soft_temp_limit_history:throttled==null ? null : !!(throttled&0x80000),
        power_flags:throttled,
        cpu_temperature_c:+(trim(readfile('/sys/class/thermal/thermal_zone0/temp') || '0'))/1000};
    result.controller={version, powered:mode==1, sample_minutes:interval,
        auto_start_on_ac:values[0x19-1]==1,
        shutdown_countdown_s:values[0x18-1], restart_countdown_s:values[0x1a-1],
        total_run_s:u32(0x1c), charging_s:u32(0x20), current_run_s:u32(0x24)};
    // Keep both raw voltages in light samples used by the shutdown watcher.
    result.sensors={battery:ina219('0x45',0.005)};
    result.voltage_reference=voltage_reference(result);
    if (result.voltage_reference.sensor_rejected)
        push(result.warnings,'两路电池电压差异超过 150 mV；低电判断回退主控读数，低压段仍需实测核对');
    if (!lite) {
        result.sensors.pi_supply=ina219('0x40',0.00725);
        result.sensors.rtc=rtc();
        let uid=bytes('/usr/sbin/i2ctransfer -y 1 w1@0x17 0xf0 r12',12);
        if (uid) {
            let serial='';for (let b in uid) serial+=sprintf('%02X',b);
            result.controller.serial=serial;
        }
    }
    if (!external) push(result.warnings,'外部输入已断开，正在使用电池');
    if (temp>=50) push(result.warnings,'电池温度偏高，请检查散热和充电环境');
    if (pogo<4700) push(result.warnings,'树莓派供电电压偏低');
    if (throttled!=null && (throttled&1)) push(result.warnings,'树莓派当前报告欠压');
    if (charge<=20) push(result.warnings,'电量估计值偏低；尚需完整充放电校准');
    return result;
}

export { sample, validRaw, voltage_reference };
