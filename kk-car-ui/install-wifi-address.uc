'use strict';
// This device-specific adjustment does not restart Wi-Fi or the network.
import { cursor } from 'uci';
import { readfile, realpath } from 'fs';
let c = cursor();
if (length(c.changes('wireless') || {})) die('Unapplied Wi-Fi changes; stopped\n');
let model = readfile('/proc/device-tree/model') || '';
let driver = realpath('/sys/class/ieee80211/phy0/device/driver') || '';
if (!match(model, /Raspberry Pi 3 Model B Plus/) || !match(driver, /\/brcmfmac$/))
    die('Only Raspberry Pi 3B+ with native brcmfmac phy0 is supported\n');
if (c.get('wireless','default_radio0','device') != 'radio0' ||
    c.get('wireless','default_radio0','mode') != 'ap')
    die('Expected radio0 AP section is missing\n');
let mac = trim(readfile('/sys/class/ieee80211/phy0/macaddress') || '');
if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) ||
    mac == '00:00:00:00:00:00' || (int(substr(mac,0,2),16) & 1))
    die('Invalid hardware MAC address\n');
let old = c.get('wireless','default_radio0','macaddr');
if (old == mac) { print('Hardware Wi-Fi address is already pinned\n'); exit(0); }
if (old) die('An explicit Wi-Fi address already exists; review it manually\n');
c.set('wireless','default_radio0','macaddr',mac);
if (!c.commit('wireless')) die('Wi-Fi commit failed\n');
print('Hardware Wi-Fi address saved; rebuild radio0 from a wired session\n');
