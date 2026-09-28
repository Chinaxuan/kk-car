'use strict';
'require baseclass';

// Capacity and Pi-side power provide a rough planning figure, never a cutoff.
function estimate(data) {
    var b = data && data.battery || {}, input = data && data.input || {},
        pi = data && data.sensors && data.sensors.pi_supply || {};
    var capacity = b.nominal_capacity_mah, full = b.configured_full_mv,
        protect = b.configured_protect_mv, voltage = b.millivolts;
    if (!data || !data.ok || !Number.isInteger(capacity) || capacity < 500 || capacity > 10000 ||
        !Number.isFinite(full) || !Number.isFinite(protect) || full - protect < 300 ||
        !Number.isFinite(voltage) || voltage < 2500 || voltage > 4600 ||
        !pi.detected || pi.overflow || !Number.isFinite(pi.power_mw) ||
        pi.power_mw < 500 || pi.power_mw > 30000 || typeof input.external !== 'boolean')
        return {kind:'unavailable', reason:'等待有效的主控电压与树莓派功率读数'};
    // Two cells' combined nominal capacity is configured separately. Voltage is
    // only a rough fraction of the span to hardware protection, not calibrated SoC.
    var fraction = Math.max(0, Math.min(1, (voltage - protect) / (full - protect)));
    if (!input.external && fraction < 0.05)
        return {kind:'unavailable', reason:'已接近保护电压，剩余时间无法可靠推算'};
    var outputWh = capacity / 1000 * 3.7 * 0.85;
    var seconds = Math.round(outputWh * (input.external ? 1 : fraction) /
                             (pi.power_mw / 1000) * 3600);
    if (seconds < 300 || seconds > 24 * 3600)
        return {kind:'unavailable', reason:'当前估算超出可信范围'};
    return {kind:input.external ? 'full_reference' : 'remaining', seconds:seconds,
            power_w:pi.power_mw / 1000, capacity_mah:capacity};
}

return baseclass.extend({estimate:estimate});
