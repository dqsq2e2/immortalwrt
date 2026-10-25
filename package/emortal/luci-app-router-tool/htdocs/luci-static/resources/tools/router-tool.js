'use strict';
'require baseclass';
'require form';
'require fs';
'require rpc';
'require uci';

let recorder = null;

const callBoardJSON = rpc.declare({
	object: 'luci-rpc',
	method: 'getBoardJSON',
	expect: { '': {} }
});

const callInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { 'interface': [] }
});

const copy = value => value == null ? null : JSON.parse(JSON.stringify(value));
const equal = (a, b) => JSON.stringify(a ?? null) == JSON.stringify(b ?? null);

function optionEqual(option, a, b) {
	// Firewall's unchecked masquerading flags are omitted by its LuCI view.
	const optional = option.config == 'firewall' && option.type == 'zone' && [ 'masq', 'masq6' ].includes(option.key);
	return equal(optional ? a ?? '0' : a, optional ? b ?? '0' : b);
}

function sectionValues(config, sid) {
	const section = uci.sections(config).find(s => s['.name'] == sid);
	return section && Object.fromEntries(Object.keys(section).filter(k => k[0] != '.').map(k => [ k, copy(uci.get(config, sid, k)) ]).filter(v => v[1] != null));
}

function refuse(message) {
	console.warn('[router-tool] ' + message);
	const error = new Error(message);
	error.routerToolConflict = true;
	throw error;
}

function recordOption(state, config, sid, key) {
	if (!state.created.some(s => s.config == config && s.sid == sid) &&
		!state.options.some(o => o.config == config && o.sid == sid && o.key == key)) {
		const option = { config, sid, key, type: uci.get(config, sid)?.['.type'] };
		if (state.mode == 'ap') option.value = copy(uci.get(config, sid, key));
		state.options.push(option);
	}
}

function finishSnapshot(state) {
	for (const option of state.options) option.expected = copy(uci.get(option.config, option.sid, option.key));
	for (const section of state.created) {
		section.type = uci.get(section.config, section.sid)?.['.type'];
		section.values = sectionValues(section.config, section.sid);
	}
	return JSON.stringify(state);
}

function setOptions(config, sid, values) {
	for (const [ key, value ] of Object.entries(values)) {
		if (recorder) recordOption(recorder, config, sid, key);
		if (value == null) uci.unset(config, sid, key);
		else uci.set(config, sid, key, value);
	}
}

function ensure(config, type, sid) {
	const section = uci.get(config, sid);
	if (section && section['.type'] != type) refuse(_('Mode switch refused: section type changed at') + ` ${config}.${sid}`);
	if (section == null) {
		uci.add(config, type, sid);
		if (recorder) recorder.created.push({ config, sid });
	}
	return sid;
}

function findUnique(config, type, predicate) {
	const found = uci.sections(config, type).filter(predicate);
	if (found.length > 1) refuse(_('Mode switch refused: ambiguous matching configuration sections:') + ` ${config}.${type}`);
	return found[0]?.['.name'];
}

function reserve(config, type, sid) {
	if (uci.get(config, sid)) refuse(_('Mode switch refused: reserved section already exists at') + ` ${config}.${sid}`);
	return ensure(config, type, sid);
}

function globals() {
	return uci.sections('network', 'globals')[0]?.['.name'];
}

function wan6Device() {
	const proto = uci.get('network', 'wan', 'proto');
	const device = uci.get('network', 'wan', 'device');
	// Ethernet IPv6 must be available before the IPv4 DHCP lease arrives.
	// PPP and other protocols still need their negotiated L3 device.
	return [ 'dhcp', 'static' ].includes(proto) &&
		typeof device == 'string' && device.length && !/\s/.test(device) ? device : '@wan';
}

function readSnapshot(sid, option, mode) {
	try {
		const state = JSON.parse(uci.get('network', sid, option) || 'null');
		const validValue = v => v == null || typeof v == 'string' || Array.isArray(v) && v.every(x => typeof x == 'string');
		const validSection = s => s && [ 'network', 'dhcp', 'firewall', 'wireless' ].includes(s.config) && typeof s.sid == 'string' && s.sid.length && typeof s.type == 'string' && s.type.length;
		const seen = new Set();
		if (state?.version != 1 || ![ 'main', 'sub', 'ap' ].includes(mode) || state.mode != mode || typeof state.subnet_done != 'boolean' ||
			!Array.isArray(state.options) || !Array.isArray(state.created) || !state.options.length && !state.created.length) return null;
		for (const s of state.created) {
			const id = `${s.config}/${s.sid}`;
			if (!validSection(s) || !s.values || Array.isArray(s.values) || typeof s.values != 'object' || !Object.values(s.values).every(validValue) || seen.has(id)) return null;
			seen.add(id);
		}
		for (const o of state.options) {
			const id = `${o.config}/${o.sid}/${o.key}`;
			if (!validSection(o) || typeof o.key != 'string' || !o.key.length || o.key[0] == '.' || (mode == 'ap' && (!Object.hasOwn(o, 'value') || !validValue(o.value))) || !Object.hasOwn(o, 'expected') ||
				!validValue(o.expected) || seen.has(id) || seen.has(`${o.config}/${o.sid}`)) return null;
			seen.add(id);
		}
		return state;
	}
	catch (e) { return null; }
}

function checkSnapshot(state, live, wanTrigger) {
	if (!state) refuse(_('Mode switch refused: saved configuration snapshot is missing or invalid.'));
	const get = (config, sid, key) => {
		if (key == null) return (live ? live[config]?.[sid] : uci.get(config, sid))?.['.type'];
		return live ? live[config]?.[sid]?.[key] : uci.get(config, sid, key);
	};
	const conflicts = [];
	for (const o of state.options) {
		if (wanTrigger && o.config == 'network' && o.sid == 'wan' && o.key == 'proto') continue;
		if (get(o.config, o.sid) != o.type || !optionEqual(o, get(o.config, o.sid, o.key), o.expected))
			conflicts.push(`${o.config}.${o.sid}.${o.key}`);
	}
	for (const s of state.created) {
		const section = live?.[s.config]?.[s.sid];
		const values = live ? section && Object.fromEntries(Object.entries(section).filter(v => v[0][0] != '.')) : sectionValues(s.config, s.sid);
		if (get(s.config, s.sid) != s.type || !values ||
			Array.from(new Set(Object.keys(values).concat(Object.keys(s.values)))).some(key =>
				!optionEqual({ ...s, key }, values[key], s.values[key]))) conflicts.push(`${s.config}.${s.sid}`);
	}
	if (conflicts.length) refuse(_('Mode switch refused: user changed related options:') + ' ' + conflicts.join(', '));
}

function verifyLiveSnapshot(sid, selected, enabled, before) {
	const role = uci.get('network', 'wan', 'proto') == 'pppoe' ? 'main' : 'sub';
	const previous = readSnapshot(sid, 'router_tool_state', uci.get('network', sid, 'router_tool_auto'));
	const protocol = previous?.options.find(o => o.config == 'network' && o.sid == 'wan' && o.key == 'proto');
	if (selected == enabled && (enabled || uci.get('network', sid, 'router_tool_auto') == role &&
		(!protocol || protocol.expected == uci.get('network', 'wan', 'proto')))) return Promise.resolve();
	const configs = [ 'network', 'dhcp', 'firewall', 'wireless' ];
	return Promise.all(configs.map(config => uci.callLoad(config))).then(values => {
		const live = Object.fromEntries(configs.map((config, i) => [ config, values[i] ]));
		if (!enabled && live.network[sid]?.router_tool_ap_state)
			refuse(_('Mode switch refused: an AP snapshot exists while AP mode is disabled. Restore AP mode and use LuCI to switch back.'));
		for (const key of [ 'router_tool_auto', 'router_tool_ap', 'router_tool_state', 'router_tool_ap_state' ])
			if (!equal(live.network[sid]?.[key], uci.get('network', sid, key)))
				refuse(_('Mode switch refused: configuration changed while this page was open. Reload the page.'));
		const state = readSnapshot(sid, enabled ? 'router_tool_ap_state' : 'router_tool_state', enabled ? 'ap' : uci.get('network', sid, 'router_tool_auto'));
		if (enabled || uci.get('network', sid, 'router_tool_auto') || uci.get('network', sid, 'router_tool_state')) {
			checkSnapshot(state, before, !selected && !enabled);
			checkSnapshot(state, live, !selected && !enabled);
		}
	});
}

function retainedOptions(map, sid, enabled) {
	const state = readSnapshot(sid, enabled ? 'router_tool_ap_state' : 'router_tool_state', enabled ? 'ap' : uci.get('network', sid, 'router_tool_auto'));
	const options = (state?.options || []).concat((state?.created || []).flatMap(s =>
		Object.entries(s.values).map(([ key, expected ]) => ({ config: s.config, sid: s.sid, key, expected }))));
	return options.filter(o => {
		if (o.expected == null || !equal(o.expected, uci.get(o.config, o.sid, o.key))) return false;
		const field = map.lookupOption?.(o.key, o.sid, o.config)?.[0];
		if (!field || !field.isActive(o.sid)) return true;
		// LuCI represents disabled odhcpd services with an empty choice.
		const value = o.config == 'dhcp' && [ 'dhcpv4', 'ra', 'dhcpv6', 'ndp' ].includes(o.key) && o.expected == 'disabled' ? '' : o.expected;
		return (equal(value, field.default) || value === '') && equal(value, field.formvalue(o.sid));
	});
}

function recordContext(state, data) {
	for (const [ config, sections ] of Object.entries(data.switch_watch || {}))
		for (const [ sid, options ] of Object.entries(sections))
			for (const key of options) recordOption(state, config, sid, key);
	const bridge = findUnique('network', 'device', s => s.name == uci.get('network', 'lan', 'device') && s.type == 'bridge');
	if (bridge) for (const key of [ 'name', 'type', 'ports' ]) recordOption(state, 'network', bridge, key);
	for (const s of uci.sections('wireless', 'wifi-iface'))
		if ([ 'ap', 'ap-wds' ].includes(s.mode) && L.toArray(s.network).some(n => [ 'lan', 'wan', 'wan6' ].includes(n)))
			recordOption(state, 'wireless', s['.name'], 'network');
}

function boardPorts(board, name) {
	return L.toArray(board?.network?.[name]?.ports || board?.network?.[name]?.device);
}

function topology(context) {
	const device = uci.get('network', 'lan', 'device') || 'br-lan';
	const bridgeId = findUnique('network', 'device', s => s.name == device && s.type == 'bridge');
	const bridge = bridgeId ? uci.get('network', bridgeId) : null;
	const bridgeName = bridge ? device : 'br-lan';
	const wan = uci.get('network', 'wan', 'device') || boardPorts(context.board, 'wan')[0];
	const ports = bridge ? L.toArray(uci.get('network', bridge['.name'], 'ports')) :
		boardPorts(context.board, 'lan').concat(device != bridgeName ? [ device ] : []);
	const physical = Object.keys(context.board?.network || {}).flatMap(name => boardPorts(context.board, name));
	return { bridge, bridgeName, wan, ports: Array.from(new Set(ports.concat(physical, wan || []))) };
}

function validateAp(topo, context) {
	if (!Object.keys(context.board?.network || {}).length)
		throw new Error(_('Cannot read board port assignments. Configure AP ports manually.'));
	if (!topo.wan || topo.wan.startsWith('@'))
		throw new Error(_('Cannot identify the Ethernet WAN device. Configure LAN/WAN devices first.'));
	const devices = uci.sections('network', 'device');
	if (uci.sections('network', 'switch').length || uci.sections('network', 'switch_vlan').length ||
		uci.sections('network', 'bridge-vlan').some(s => s.device == topo.bridgeName) ||
		devices.some(s => s.name != topo.bridgeName && L.toArray(s.ports).some(port => topo.ports.includes(port))) ||
		devices.some(s => topo.ports.includes(s.name) && s.type && ![ '8023', 'ethernet' ].includes(s.type)) ||
		topo.ports.some(port => /[.@:]/.test(port) || port == topo.bridgeName || /^(br-|wlan|phy)/.test(port)))
		throw new Error(_('Automatic AP conversion requires plain Ethernet ports. Configure VLAN or switch topologies manually.'));
}

function zone(name) {
	return findUnique('firewall', 'zone', s => s.name == name) || reserve('firewall', 'zone', `router_tool_${name}`);
}

function configureFirewall(role, data) {
	const lan = zone('lan'), wan = zone('wan');
	for (const section of uci.sections('firewall', 'zone')) {
		const networks = L.toArray(uci.get('firewall', section['.name'], 'network')).filter(n => ![ 'lan', 'wan', 'wan6' ].includes(n));
		if (section['.name'] == lan) networks.push('lan', ...(role == 'relay_ap' ? [ 'wan6' ] : []));
		if (section['.name'] == wan && role != 'relay_ap') networks.push('wan', 'wan6');
		setOptions('firewall', section['.name'], { network: networks.length ? networks : null });
	}
	for (const [ name, sid ] of [ [ 'lan', lan ], [ 'wan', wan ] ])
		setOptions('firewall', sid, { name, ...data.zones[name], ...(role == 'relay_ap' ? { masq: '0' } : {}) });
	for (const section of uci.sections('firewall', 'defaults'))
		setOptions('firewall', section['.name'], { disable_ipv6: null });
	const forwarding = findUnique('firewall', 'forwarding', s => s.src == 'lan' && s.dest == 'wan') || reserve('firewall', 'forwarding', 'router_tool_lan_wan');
	setOptions('firewall', forwarding, { src: 'lan', dest: 'wan', enabled: role == 'relay_ap' ? '0' : '1', family: null });
	for (const [ name, values ] of Object.entries(data.rules)) {
		const existing = findUnique('firewall', 'rule', s => s.name == name);
		const enabled = role != 'relay_ap' && (name != 'Router-Tool-DHCPv6-Relay' || role == 'sub');
		if (!enabled && !existing) continue;
		const sid = existing || reserve('firewall', 'rule', 'router_tool_' + name.toLowerCase().replaceAll('-', '_'));
		if (!enabled) setOptions('firewall', sid, { enabled: '0' });
		else setOptions('firewall', sid, { name, enabled: '1', src: 'wan', target: 'ACCEPT', src_ip: null, dest_ip: null, ...values });
	}
}

function subnet(value, netmask) {
	const parts = String(value).split('/');
	if (parts.length > 2) return null;
	const [ address, cidr ] = parts;
	const octets = address.split('.');
	if (octets.length != 4 || octets.some(n => !/^\d+$/.test(n) || Number(n) > 255)) return null;
	if (cidr != null && !/^\d+$/.test(cidr)) return null;
	let prefix = cidr != null ? Number(cidr) : 24;
	if (cidr == null && netmask) {
		const masks = String(netmask).split('.');
		if (masks.length != 4 || masks.some(n => !/^\d+$/.test(n) || Number(n) > 255)) return null;
		const bits = masks.map(n => Number(n).toString(2).padStart(8, '0')).join('');
		if (!/^1*0*$/.test(bits) || bits.length != 32) return null;
		prefix = bits.indexOf('0') == -1 ? 32 : bits.indexOf('0');
	}
	if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) return null;
	return { address: octets.reduce((n, v) => (n << 8) | Number(v), 0) >>> 0, prefix };
}

function avoidSubnetConflict(context) {
	if (uci.get('network', 'lan', 'proto') != 'static') return;
	const upstream = context.upstream4.map(address => subnet(address)).filter(Boolean);
	const lan = L.toArray(uci.get('network', 'lan', 'ipaddr')).map(address => subnet(address, uci.get('network', 'lan', 'netmask'))).filter(Boolean);
	const overlaps = (a, b) => {
		const prefix = Math.min(a.prefix, b.prefix);
		const mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
		return (a.address & mask) == (b.address & mask);
	};
	if (!lan.some(a => upstream.some(b => overlaps(a, b)))) return;
	const occupied = upstream.slice();
	for (const section of uci.sections('network', 'interface'))
		if (section['.name'] != 'lan')
			occupied.push(...L.toArray(section.ipaddr).map(address => subnet(address, section.netmask)).filter(Boolean));
	for (let i = 2; i < 255; i++) {
		const address = `192.168.${i}.1/24`;
		if (occupied.every(b => !overlaps(subnet(address), b))) {
			console.info(`[router-tool] LAN subnet overlaps upstream; staging ${address}`);
			setOptions('network', 'lan', { ipaddr: address, netmask: null });
			return;
		}
	}
	throw new Error(_('No free LAN subnet was found. Configure a non-overlapping IPv4 subnet manually.'));
}

function synchronize(sid, context) {
	if (uci.get('network', sid, 'router_tool_ap') == '1') return;
	const role = uci.get('network', 'wan', 'proto') == 'pppoe' ? 'main' : 'sub';
	if (uci.get('network', sid, 'router_tool_auto') != role) {
		console.info(`[router-tool] Preparing ${role} router presets`);
		const state = { version: 1, mode: role, options: [], created: [], subnet_done: role != 'sub' };
		recorder = state;
		try {
			for (const group of [ context.presets.common, context.presets.roles[role] ])
				for (const config of [ 'network', 'dhcp' ])
					for (const [ name, options ] of Object.entries(group[config] || {})) {
						ensure(config, config == 'network' ? 'interface' : 'dhcp', name);
						setOptions(config, name, config == 'network' && name == 'wan6' ?
							{ ...options, device: wan6Device() } : options);
					}
			configureFirewall(role, context.presets.firewall);
			recordContext(state, context.presets);
			if (role == 'sub' && context.upstream4.length && context.upstreamProtocol == uci.get('network', 'wan', 'proto')) {
				avoidSubnetConflict(context);
				state.subnet_done = true;
			}
		}
		finally { recorder = null; }
		uci.set('network', sid, 'router_tool_auto', role);
		uci.set('network', sid, 'router_tool_state', finishSnapshot(state));
	}
	else {
		const state = readSnapshot(sid, 'router_tool_state', role);
		const option = state?.options.find(o => o.config == 'network' && o.sid == 'wan' && o.key == 'proto');
		if (option && option.expected != uci.get('network', 'wan', 'proto')) {
			option.expected = uci.get('network', 'wan', 'proto');
			uci.set('network', sid, 'router_tool_state', JSON.stringify(state));
		}
	}
}

function enableAp(sid, context) {
	const topo = topology(context);
	validateAp(topo, context);
	console.info(`[router-tool] Preparing AP mode on ${topo.bridgeName}; Ethernet ports: ${topo.ports.join(' ')}`);
	const state = { version: 1, mode: 'ap', options: [], created: [], subnet_done: true };
	recorder = state;
	try {
		for (const name of [ 'lan', 'wan', 'wan6' ]) ensure('network', 'interface', name);
		const bridge = topo.bridge?.['.name'] || ensure('network', 'device', 'router_tool_bridge');
		setOptions('network', bridge, { name: topo.bridgeName, type: 'bridge', ports: topo.ports });
		setOptions('network', 'wan', { proto: 'none', device: null, disabled: '1', auto: '0' });
		for (const section of uci.sections('network', 'interface'))
			if (![ 'lan', 'wan', 'wan6' ].includes(section['.name']) && topo.ports.includes(uci.get('network', section['.name'], 'device')))
				setOptions('network', section['.name'], { disabled: '1', auto: '0' });
		setOptions('network', 'lan', { device: topo.bridgeName, proto: 'dhcp', ipaddr: null, netmask: null, gateway: null, dns: null,
			ip6addr: null, ip6gw: null, ip6assign: null, ip6class: null, ip6ifaceid: null, ipv6: '0', delegate: '0', disabled: null, peerdns: '1', defaultroute: '1', auto: '1' });
		setOptions('network', 'wan6', { proto: 'dhcpv6', device: topo.bridgeName, reqaddress: 'try', reqprefix: 'no', delegate: '0',
			defaultroute: '1', peerdns: '1', noslaaconly: '0', forceprefix: '0', disabled: null, auto: '1' });
		for (const name of [ 'lan', 'wan', 'wan6' ]) {
			ensure('dhcp', 'dhcp', name);
			setOptions('dhcp', name, { interface: name, ignore: '1', dhcpv4: 'disabled', ra: 'disabled', dhcpv6: 'disabled', ndp: 'disabled', master: '0', ndproxy_routing: null });
		}
		for (const section of uci.sections('wireless', 'wifi-iface')) {
			const networks = L.toArray(uci.get('wireless', section['.name'], 'network'));
			if ([ 'ap', 'ap-wds' ].includes(section.mode) && networks.some(name => [ 'lan', 'wan', 'wan6' ].includes(name)))
				setOptions('wireless', section['.name'], { network: Array.from(new Set(networks.map(name => [ 'wan', 'wan6' ].includes(name) ? 'lan' : name))) });
		}
		configureFirewall('relay_ap', context.presets.firewall);
	}
	finally { recorder = null; }
	uci.set('network', sid, 'router_tool_ap_state', finishSnapshot(state));
	uci.set('network', sid, 'router_tool_ap', '1');
	console.info(`[router-tool] AP configuration staged; saved ${state.options.length} options and ${state.created.length} new sections; awaiting Save & Apply`);
}

function disableAp(sid) {
	const state = readSnapshot(sid, 'router_tool_ap_state', 'ap');
	for (const option of state.options.slice().reverse())
		if (uci.get(option.config, option.sid) != null)
			setOptions(option.config, option.sid, { [option.key]: option.value });
	for (const section of state.created.slice().reverse()) uci.remove(section.config, section.sid);
	uci.unset('network', sid, 'router_tool_ap_state');
	uci.set('network', sid, 'router_tool_ap', '0');
	console.info(`[router-tool] Previous configuration restored from AP snapshot; ${state.options.length} options; awaiting Save & Apply`);
}

return baseclass.extend({
	attach(map) {
		if (map._routerToolAttached) return;
		map._routerToolAttached = true;
		for (const config of [ 'network', 'dhcp', 'firewall', 'wireless' ]) map.chain(config);
		const context = { board: null, upstream4: [], upstreamProtocol: null, presets: null };
		const load = map.load.bind(map);
		map.load = function() {
			return Promise.all([ load(), callBoardJSON().catch(e => {
				console.warn('[router-tool] Board port assignments could not be loaded: ' + e.message);
				return {};
			}),
				fs.read('/usr/share/router-tool/auto.json'), callInterfaces().catch(() => []) ]).then(data => {
				context.board = data[1];
				context.presets = JSON.parse(data[2]);
				const upstream = data[3].find(n => n.interface == 'wan') || {};
				context.upstreamProtocol = upstream.proto;
				context.upstream4 = upstream.up ? (upstream['ipv4-address'] || []).map(a => `${a.address}/${a.mask}`) : [];
			}).catch(e => {
				console.error('[router-tool] Failed to load role settings: ' + e.message);
				throw e;
			});
		};
		const save = map.save.bind(map);
		map.save = function(cb, silent) {
			let previous = null;
			const sid = globals();
			const option = map._routerToolOption;
			const enabled = uci.get('network', sid, 'router_tool_ap') == '1';
			const selected = option ? option.formvalue(sid) == '1' : enabled;
			const retained = retainedOptions(map, sid, enabled);
			// Validate the loaded configuration, before form parsing removes
			// default or inactive options during a protocol switch. Check fresh
			// server values as well, so an external edit still stops the switch.
			const before = Object.fromEntries([ 'network', 'dhcp', 'firewall', 'wireless' ].map(config =>
				[ config, Object.fromEntries(uci.sections(config).map(s => [ s['.name'], copy(uci.get(config, s['.name'])) ])) ]));
			// Only the standard map save/apply flow persists these changes.
			return save(() => verifyLiveSnapshot(sid, selected, enabled, before).then(() => {
				previous = copy(uci.state);
				// Preserve unchanged owned values which LuCI removes as default
				// or inactive fields. Explicit active edits remain user changes.
				for (const o of retained)
					if (uci.get(o.config, o.sid, o.key) == null) uci.set(o.config, o.sid, o.key, copy(o.expected));
				if (sid && selected != enabled) {
					if (selected) enableAp(sid, context);
					else disableAp(sid);
				}
				// Cancelling AP must restore the snapshot exactly. A staged AP
				// save can still have the old live LAN address; it is not a WAN
				// lease. The backend checks the real WAN after applying changes.
				if (sid && !selected && !enabled) synchronize(sid, context);
				return cb ? cb() : undefined;
			}), silent).catch(e => {
				if (previous) uci.state = previous;
				console.error('[router-tool] Failed to save role settings: ' + e.message);
				if (e.routerToolConflict)
					return fs.exec('/usr/bin/logger', [ '-t', 'router-tool', '-p', 'daemon.warning', e.message ]).catch(error => {
						console.warn('[router-tool] Could not write system log: ' + error.message);
					}).then(() => { throw e; });
				throw e;
			});
		};
	},

	addGlobal(section) {
		const o = section.option(form.Flag, 'router_tool_ap', _('Relay AP mode'),
			_('Manually enable to bridge all Ethernet ports and obtain IPv4/IPv6 from the upstream router; disable to restore the previous settings. When disabled, PPPoE automatically uses main-router mode and other WAN protocols use sub-router mode.') + ' ' +
			_('Mode switches stop if related settings have been edited.'));
		o.default = '0';
		o.rmempty = false;
		o.write = function() {};
		section.map._routerToolOption = o;
		return o;
	}
});
