// Shared preset data is also used by the LuCI post-parse save callback.
import { read_snapshot, check_snapshot, record_option, record_context, finish_snapshot } from './snapshot.uc';

function sections(uci, config, type) {
	let result = [];
	uci.foreach(config, type, section => push(result, section));
	return result;
}

function array(value) {
	return type(value) == 'array' ? value : value == null ? [] : split(value, /\s+/);
}

function wan6_device(uci) {
	let proto = uci.get('network', 'wan', 'proto');
	let device = uci.get('network', 'wan', 'device');
	// Ethernet IPv6 must be available before the IPv4 DHCP lease arrives.
	// PPP and other protocols still need their negotiated L3 device.
	return index([ 'dhcp', 'static' ], proto) >= 0 &&
		type(device) == 'string' && length(device) && !match(device, /\s/) ? device : '@wan';
}

function subnet(value, netmask) {
	let parts = split('' + value, '/');
	if (length(parts) > 2) return null;
	let octets = split(parts[0], '.');
	if (length(octets) != 4 || length(filter(octets, n => !match(n, /^\d+$/) || int(n) > 255))) return null;
	if (length(parts) > 1 && !match(parts[1], /^\d+$/)) return null;
	let prefix = length(parts) > 1 ? int(parts[1]) : 24;
	if (length(parts) < 2 && netmask) {
		let masks = split(netmask, '.');
		if (length(masks) != 4) return null;
		let mask = 0;
		for (let part in masks) {
			if (!match(part, /^\d+$/) || int(part) > 255) return null;
			mask = (mask << 8) | int(part);
		}
		prefix = 0;
		while (prefix < 32 && (mask & (1 << (31 - prefix)))) prefix++;
		if ((mask & 0xffffffff) != (prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff)) return null;
	}
	if (prefix == null || prefix < 0 || prefix > 32) return null;
	let address = 0;
	for (let part in octets) address = (address << 8) | int(part);
	return { address: address & 0xffffffff, prefix };
}

function overlaps(a, b) {
	let prefix = min(a.prefix, b.prefix);
	let mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
	return (a.address & mask) == (b.address & mask);
}

export function synchronize(uci, data, upstream4, target) {
	let changed = {};
	let recorder = null;
	function ensure(config, type_name, sid) {
		let section = uci.get_all(config, sid);
		if (section && section['.type'] != type_name) die(`Mode switch refused: section type changed at ${config}.${sid}`);
		if (!section) {
			if (!uci.set(config, sid, type_name)) die(`Cannot create ${config}.${sid}`);
			changed[config] = true;
			if (recorder) push(recorder.created, { config, sid });
		}
		return sid;
	}
	function find_unique(config, type_name, predicate) {
		let found = filter(sections(uci, config, type_name), predicate);
		if (length(found) > 1) die(`Mode switch refused: ambiguous matching sections in ${config}.${type_name}`);
		return found[0]?.['.name'];
	}
	function reserve(config, type_name, sid) {
		if (uci.get_all(config, sid)) die(`Mode switch refused: reserved section already exists at ${config}.${sid}`);
		return ensure(config, type_name, sid);
	}
	function set(config, sid, values) {
		for (let key, value in values) {
			if (recorder) record_option(uci, recorder, config, sid, key);
			let previous = uci.get(config, sid, key);
			if (value == null && previous == null) continue;
			if (sprintf('%J', value) == sprintf('%J', previous)) continue;
			let ok = value == null ? uci.delete(config, sid, key) : uci.set(config, sid, key, value);
			if (!ok) die(`Cannot set ${config}.${sid}.${key}`);
			changed[config] = true;
		}
	}
	let sid = sections(uci, 'network', 'globals')[0]?.['.name'] || ensure('network', 'globals', 'globals');
	let ap = uci.get('network', sid, 'router_tool_ap') == '1';
	let role = uci.get('network', 'wan', 'proto') == 'pppoe' ? 'main' : 'sub';
	let previous = uci.get('network', sid, 'router_tool_auto');
	let saved = uci.get('network', sid, 'router_tool_state');
	let state = previous || saved ? read_snapshot(saved, previous) : null;
	if (!ap && previous != role && state) check_snapshot(uci, state, true);
	// Apply platform defaults once; preserve explicit user choices on reload
	// and role changes, including disabled RPS/RFS and all-CPU steering.
	let defaults = data.platform_defaults?.[target] || data.platform_defaults?.[split(target || '', '/')[0]];
	if (defaults?.network && uci.get('network', sid, 'router_tool_steering_defaults_done') != '1') {
		for (let option, value in defaults.network)
			if (uci.get('network', sid, option) == null)
				set('network', sid, { [option]: value });
		set('network', sid, { router_tool_steering_defaults_done: '1' });
	}
	if (defaults?.firewall && uci.get('network', sid, 'router_tool_offload_defaults_done') != '1') {
		let firewall = sections(uci, 'firewall', 'defaults')[0]?.['.name'] || ensure('firewall', 'defaults', 'defaults');
		// Initialize the preset even when firewall4 ships its own defaults.
		// The marker preserves later user choices, including LuCI "None",
		// which removes both options.
		set('firewall', firewall, defaults.firewall);
		set('network', sid, { router_tool_offload_defaults_done: '1' });
	}
	// Keep later user-added ULA prefixes after the one-time cleanup.
	if (uci.get('network', sid, 'router_tool_ula_cleanup_done') != '1')
		set('network', sid, { ula_prefix: null, router_tool_ula_cleanup_done: '1' });
	if (ap) return keys(changed);
	if (previous != role) {
		state = { version: 1, mode: role, options: [], created: [], subnet_done: role != 'sub' };
		recorder = state;
		for (let group in [ data.common, data.roles[role] ])
			for (let config in [ 'network', 'dhcp' ])
				for (let name, options in group[config] || {}) {
					ensure(config, config == 'network' ? 'interface' : 'dhcp', name);
					set(config, name, config == 'network' && name == 'wan6' ?
						{ ...options, device: wan6_device(uci) } : options);
				}
		let zones = {};
		for (let name in [ 'lan', 'wan' ]) {
			zones[name] = find_unique('firewall', 'zone', section => section.name == name) || reserve('firewall', 'zone', 'router_tool_' + name);
			set('firewall', zones[name], { name, ...data.firewall.zones[name] });
		}
		for (let section in sections(uci, 'firewall', 'zone')) {
			let networks = filter(array(uci.get('firewall', section['.name'], 'network')), name => index([ 'lan', 'wan', 'wan6' ], name) < 0);
			if (section['.name'] == zones.lan) push(networks, 'lan');
			if (section['.name'] == zones.wan) push(networks, 'wan', 'wan6');
			set('firewall', section['.name'], { network: length(networks) ? networks : null });
		}
		for (let section in sections(uci, 'firewall', 'defaults')) set('firewall', section['.name'], { disable_ipv6: null });
		let forward = find_unique('firewall', 'forwarding', section => section.src == 'lan' && section.dest == 'wan') || reserve('firewall', 'forwarding', 'router_tool_lan_wan');
		set('firewall', forward, { src: 'lan', dest: 'wan', enabled: '1', family: null });
		for (let name, values in data.firewall.rules) {
			let existing = find_unique('firewall', 'rule', section => section.name == name);
			let enabled = name != 'Router-Tool-DHCPv6-Relay' || role == 'sub';
			if (!enabled && !existing) continue;
			let rule = existing || reserve('firewall', 'rule', 'router_tool_' + replace(lc(name), /-/g, '_'));
			set('firewall', rule, enabled ? { name, enabled: '1', src: 'wan', target: 'ACCEPT', src_ip: null, dest_ip: null, ...values } : { enabled: '0' });
		}
		record_context(uci, state, data);
		recorder = null;
		set('network', sid, { router_tool_auto: role });
	}
	// Await the first lease, then check the LAN subnet once for this mode.
	// Later lease events must not overwrite a user's addressing decisions.
	if (role == 'sub' && !state.subnet_done && length(upstream4 || [])) {
		if (previous == role) check_snapshot(uci, state);
		recorder = state;
		let upstream = filter(map(upstream4 || [], address => subnet(address)), address => address != null);
		let lan = filter(map(array(uci.get('network', 'lan', 'ipaddr')), address => subnet(address, uci.get('network', 'lan', 'netmask'))), address => address != null);
		if (uci.get('network', 'lan', 'proto') == 'static' && length(filter(lan, a => length(filter(upstream, b => overlaps(a, b)))))) {
			let occupied = [ ...upstream ];
			for (let section in sections(uci, 'network', 'interface'))
				if (section['.name'] != 'lan')
					for (let address in array(section.ipaddr)) {
						let parsed = subnet(address, section.netmask);
						if (parsed) push(occupied, parsed);
					}
			let address = null;
			for (let i = 2; i < 255; i++) {
				let candidate = `192.168.${i}.1/24`;
				if (!length(filter(occupied, b => overlaps(subnet(candidate), b)))) { address = candidate; break; }
			}
			if (!address) die('No non-overlapping IPv4 LAN subnet found');
			set('network', 'lan', { ipaddr: address, netmask: null });
		}
		recorder = null;
		state.subnet_done = true;
		set('network', sid, { router_tool_state: finish_snapshot(uci, state) });
	}
	else if (previous != role) set('network', sid, { router_tool_state: finish_snapshot(uci, state) });
	else {
		for (let option in state.options)
			if (option.config == 'network' && option.sid == 'wan' && option.key == 'proto' && option.expected != uci.get('network', 'wan', 'proto')) {
				check_snapshot(uci, state, true);
				option.expected = uci.get('network', 'wan', 'proto');
				set('network', sid, { router_tool_state: sprintf('%J', state) });
			}
	}
	return keys(changed);
}
