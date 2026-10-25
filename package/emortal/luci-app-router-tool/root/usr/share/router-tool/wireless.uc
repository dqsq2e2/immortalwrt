// Project defaults for untouched APs. The caller owns the UCI transaction.
function array(value) {
	if (type(value) == 'array') return value;
	if (type(value) == 'object') {
		let result = [];
		for (let key, item in value) push(result, item);
		return result;
	}
	return value == null ? [] : [ value ];
}

function capabilities(board, radio, band) {
	for (let name, phy in board?.wlan || {}) {
		if (!(radio.phy && name == radio.phy) &&
			!(radio.path && index(array(phy.path), radio.path) >= 0)) continue;
		let info = phy.info;
		let caps = info?.bands?.[band];
		if (type(caps) != 'object') continue;
		if (radio.radio != null && '' + radio.radio != '' && type(info.radios) == 'array') {
			let match = filter(info.radios, entry => '' + entry.index == '' + radio.radio)[0];
			if (type(match?.bands?.[band]) != 'object') return null;
		}
		let modes = array(caps.modes);
		if (!length(modes)) return null;
		let width = match('' + caps.max_width, /^\d+$/) ? int(caps.max_width) : 20;
		return { modes, width };
	}
	return null;
}

function htmode(caps, requested) {
	for (let width in [ 160, 80, 40, 20 ]) {
		if (width > requested || width > caps.width) continue;
		for (let mode in [ 'EHT', 'HE', 'VHT', 'HT' ])
			if (index(caps.modes, mode + width) >= 0) return mode + width;
	}
	return null;
}

export function synchronize_wireless(uci, board) {
	if (type(board?.wlan) != 'object') return false;
	let radios = [], interfaces = [], changed = false;
	uci.foreach('wireless', 'wifi-device', section => push(radios, section));
	uci.foreach('wireless', 'wifi-iface', section => push(interfaces, section));
	function set(sid, values) {
		for (let option, value in values) {
			let old = uci.get('wireless', sid, option);
			if (sprintf('%J', old) == sprintf('%J', value)) continue;
			let ok = value == null ? uci.delete('wireless', sid, option) : uci.set('wireless', sid, option, value);
			if (!ok) die(`Cannot set wireless.${sid}.${option}`);
			changed = true;
		}
	}
	for (let radio in radios) {
		if (radio.router_tool_defaults_done == '1') continue;
		let attached = filter(interfaces, iface => index(array(iface.device), radio['.name']) >= 0);
		// Decide once as soon as a radio has interfaces. Custom SSIDs and
		// station/mesh/WDS backhauls are explicit user configuration.
		if (!length(attached)) continue;
		let has_ap = length(filter(attached, iface => iface.mode == 'ap')) > 0;
		if (length(filter(attached, iface => iface.mode != 'ap' || iface.wds == '1' || length(array(iface.device)) != 1 || iface.mlo == '1'))) {
			set(radio['.name'], { router_tool_defaults_done: '1' });
			continue;
		}
		let aps = attached;
		if (!has_ap) { set(radio['.name'], { router_tool_defaults_done: '1' }); continue; }
		if (length(filter(aps, iface => iface.ssid != 'OWRT' || iface.key != '12345678' || iface.encryption != 'psk2+ccmp'))) {
			set(radio['.name'], { router_tool_defaults_done: '1' });
			continue;
		}
		let band = { '2g': '2G', '5g': '5G', '6g': '6G' }[radio.band];
		if (!band) { set(radio['.name'], { router_tool_defaults_done: '1' }); continue; }
		let caps = capabilities(board, radio, band);
		// PHY capabilities may arrive after the first boot event. Retry when
		// they are available instead of permanently skipping the defaults.
		if (!caps) continue;
		let suffix, channel, width;
		if (band == '2G') { suffix = '2.4G'; channel = '1'; width = 20; }
		else if (band == '6G') { suffix = '6G'; channel = '33'; width = 160; }
		else if (caps.width == 80) { suffix = '5.8G'; channel = '149'; width = 80; }
		else { suffix = '5.2G'; channel = '36'; width = 160; }
		let mode = htmode(caps, width);
		if (!mode) { set(radio['.name'], { router_tool_defaults_done: '1' }); continue; }
		set(radio['.name'], { country: 'US', channel, htmode: mode });
		for (let ap in aps)
			set(ap['.name'], { ssid: 'OWRT-' + suffix, encryption: band == '6G' ? 'sae+ccmp' : 'psk2+ccmp', ieee80211w: band == '6G' ? '2' : null });
		set(radio['.name'], { router_tool_defaults_done: '1' });
	}
	return changed;
}
