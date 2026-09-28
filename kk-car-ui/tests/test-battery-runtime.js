const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,
    '../root/www/luci-static/resources/view/kkcar/battery_runtime.js'), 'utf8');
const runtime = vm.runInNewContext('(function(){' + source + '\n})()',
    {baseclass:{extend:fields => fields}});
function sample() {
    return {ok:true, input:{external:false},
        battery:{nominal_capacity_mah:3000, configured_full_mv:4200,
                 configured_protect_mv:3080, millivolts:3640,
                 percent:15, percent_calibration_unverified:true},
        sensors:{pi_supply:{detected:true, overflow:false, power_mw:5000}}};
}
let data = sample();
let remaining = runtime.estimate(data);
assert.equal(remaining.kind, 'remaining');
assert.ok(remaining.seconds > 3300 && remaining.seconds < 3500);
data.battery.percent = 90;
assert.equal(runtime.estimate(data).seconds, remaining.seconds,
    'uncalibrated UPS percentage must not change the estimate');
data.input.external = true;
assert.equal(runtime.estimate(data).kind, 'full_reference');
assert.ok(runtime.estimate(data).seconds > remaining.seconds);
data.input.external = false;
data.battery.millivolts = 3090;
assert.equal(runtime.estimate(data).kind, 'unavailable');
data.battery.millivolts = 3640;
data.sensors.pi_supply.detected = false;
assert.equal(runtime.estimate(data).kind, 'unavailable');
data.sensors.pi_supply.detected = true;
data.battery.nominal_capacity_mah = 20000;
assert.equal(runtime.estimate(data).kind, 'unavailable');
console.log('battery runtime: 6 checks passed');
