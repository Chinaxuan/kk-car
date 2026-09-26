'use strict';
import { access,popen } from 'fs';
// Caller passes only fixed event names and operational measurements. Python also
// enforces an allowlist before writing, never copies arbitrary error text.
function record_event(event,details) {
    if (!access('/etc/kk-car/diagnostics.py') || !access('/usr/bin/python3')) return false;
    let p=popen('/usr/bin/python3 /etc/kk-car/diagnostics.py event 2>/dev/null','w');
    if (!p) return false;
    p.write(sprintf('%J',{event,details}));
    let ok=p.close()==0;
    if (!ok) system('logger -t kk-car-diagnostics "event write failed"');
    return ok;
}
export { record_event };
