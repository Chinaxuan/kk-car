const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname,
    '../root/www/luci-static/resources/view/kkcar/dji-console-v2.js'), 'utf8');
const E = (tag, attrs, children) => ({ tag, attrs, children });
const page = new Function('rpc', 'view', 'E', source)(
    { declare: () => () => Promise.resolve({}) },
    { extend: value => value }, E);

const elements = {};
const rows = { replaceChildren(...items) { this.items = items; } };
const model = {
    ...page,
    smsSearch: { value: '' },
    smsListArea: rows,
    smsItems: [{ index: 1, from: 'old-sender', time: '2026-10-02 09:00:00',
        status: '已读', parts: [1], complete: true, ui_unread: null }],
    historyItems: [{ id: 'a'.repeat(64), from: 'recent-sender',
        time: '2026-10-13 12:06:00', unread: true }],
    smsCapacity: 40,
    smsSlotCount: 1,
    selectedSmsIndex: null,
    selectedHistoryId: null,
    el(id) { return elements[id] ||= {}; },
    set(id, value) { elements[id] = value; },
};
model.renderSmsItems();
assert.equal(rows.items.length, 2);
assert.equal(rows.items[0].children[0].children[0].children, 'recent-sender');
assert.match(elements['kk-dji-sms-count'].textContent, /1 条树莓派历史 · 至少 1 条未查看/);
assert.equal(elements['kk-dji-shortcut-sms'], '1 条未查看');

model.trafficOperator = { value: '' };
model.trafficRecipient = { value: '' };
model.trafficCommand = { value: '' };
model.trafficDaily = { checked: false };
model.trafficHour = { value: '' };
model.trafficQueryButton = { disabled: false };
model.capabilities = { sms_send: true };
model.trafficLoaded = false;
model.paintTraffic({ ok: true, data: { timestamp: 1, today: '2026-10-13',
    config: { operator: 'CT', recipient: '10001', command: '108', daily: true, hour: 9 },
    last_query_day: '2026-10-13', last_query_epoch: 1791864360 } });
assert.match(elements['kk-dji-traffic-schedule'], /今日已提交/);
model.paintTraffic({ ok: true, data: { timestamp: 1, today: '2026-10-13',
    config: { daily: true, hour: 9 }, last_query_day: '2026-10-12',
    last_query_blocked_day: '2026-10-13', last_query_error: '发送结果未确认' } });
assert.match(elements['kk-dji-traffic-schedule'], /自动重试已暂停/);
console.log('PASS merged SMS inbox and daily query status');
