#!/usr/bin/ucode
// Manufacturer names for the Traffic page, from each client's MAC prefix (OUI) in Wireshark's copy of the
// IEEE registry. The list (~800 KB gzipped) is only downloaded when a client has a prefix that isn't in
// /etc/traffic-vendors.json yet, and at most once a week, as its maintainers ask; it stays in /tmp (RAM)
// until a reboot. Private (randomized) MACs are skipped: the page labels those itself.
// cron runs this hourly. Keys are hex prefixes of 6, 7 or 9 digits (/24, /28, /36 blocks); "" = not registered.
import * as fs from 'fs';

const OUT = '/etc/traffic-vendors.json', LIST = '/tmp/manuf.gz';
const URL = 'https://www.wireshark.org/download/automated/data/manuf.gz';

function load(path) {
	let s = fs.readfile(path);
	if (!s) return null;
	try { return json(s); } catch (e) { return null; }
}

// "001BC51" -> "00:1B:C5:1"
function colons(h) {
	let out = [];
	for (let i = 0; i < length(h); i += 2) push(out, substr(h, i, 2));
	return join(':', out);
}

let db = load('/tmp/traffic.json') ?? load('/etc/traffic-totals.json') ?? {};
let vendors = load(OUT) ?? {};

// globally unique MACs (not randomized, not the collector's "ip x.x.x.x" entries) with no known prefix yet
let todo = [];
for (let mac in keys(db.clients ?? {})) {
	let h = uc(replace(mac, /[^0-9A-Fa-f]/g, ''));
	if (length(h) != 12 || (hex(substr(h, 0, 2)) & 2)) continue;
	if (!(substr(h, 0, 9) in vendors) && !(substr(h, 0, 7) in vendors) && !(substr(h, 0, 6) in vendors))
		push(todo, h);
}
if (!length(todo)) exit(0);

let st = fs.stat(LIST);
if (!st || time() - st.mtime > 7 * 86400) {
	// 00:00:0C (Cisco) is always in the list, so a download without it is broken
	if (system(['uclient-fetch', '-q', '-T', '60', '-O', LIST + '.tmp', URL]) != 0 ||
	    system(`zcat ${LIST}.tmp | grep -q '^00:00:0C'`) != 0) {
		fs.unlink(LIST + '.tmp');
		exit(0);   // no internet or a bad download: try again next hour
	}
	fs.rename(LIST + '.tmp', LIST);
}

let changed = false;
for (let h in todo) {
	// the list writes blocks as "AA:BB:CC", "AA:BB:CC:D0/28" and "AA:BB:CC:DD:E0/36"
	let k24 = colons(substr(h, 0, 6)), k28 = colons(substr(h, 0, 7) + '0') + '/28', k36 = colons(substr(h, 0, 9) + '0') + '/36';
	let p = fs.popen(`zcat ${LIST} | grep -E '^(${k24}|${k28}|${k36})[[:space:]]'`, 'r');
	if (!p) continue;
	let found = {};
	for (let line in split(p.read('all') ?? '', '\n')) {
		let f = split(line, '\t');
		if (length(f) >= 2) found[trim(f[0])] = trim(f[2] ?? '') || trim(f[1]);
	}
	p.close();
	if (found[k36]) vendors[substr(h, 0, 9)] = found[k36];
	else if (found[k28]) vendors[substr(h, 0, 7)] = found[k28];
	else vendors[substr(h, 0, 6)] = found[k24] ?? '';
	changed = true;
}

if (changed) {
	fs.writefile(OUT + '.tmp', sprintf('%J', vendors));
	fs.rename(OUT + '.tmp', OUT);
}
