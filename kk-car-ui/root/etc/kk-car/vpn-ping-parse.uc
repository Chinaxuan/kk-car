'use strict';

// Pure parser also used by isolated tests. Missing data must never become zero latency.
function parse_probe(raw, reason) {
    let result = {state:reason == 'vpn_down' ? 'vpn_down' : 'error', sent:null,
        received:null, loss_percent:null, avg_ms:null, min_ms:null, max_ms:null};
    if (reason == 'vpn_down') return result;
    let count = match(raw, /(\d+) packets transmitted, (\d+) packets received, (\d+)% packet loss/);
    if (!count) return result;
    let sent = +count[1], received = +count[2];
    if (sent < 1 || sent > 3 || received > sent) return result;
    result.sent = sent; result.received = received;
    result.loss_percent = (sent-received)*100.0/sent;
    if (!received) { result.state = 'timeout'; return result; }
    let timing = match(raw, /min\/avg\/max = ([0-9.]+)\/([0-9.]+)\/([0-9.]+) ms/);
    if (!timing) return result;
    for (let i = 1; i <= 3; i++)
        if (!match(timing[i], /^[0-9]+(\.[0-9]+)?$/)) return result;
    if (+timing[1] > +timing[2] || +timing[2] > +timing[3]) return result;
    result.min_ms = +timing[1]; result.avg_ms = +timing[2]; result.max_ms = +timing[3];
    result.state = received == sent ? 'ok' : 'loss';
    return result;
}
export { parse_probe };
