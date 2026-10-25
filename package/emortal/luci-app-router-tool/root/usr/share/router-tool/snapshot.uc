// Snapshots describe only options owned by a preset, plus complete new sections.
export function section_values(section) {
	let result = {};
	for (let key, value in section || {})
		if (substr(key, 0, 1) != '.') result[key] = value;
	return result;
}

export function equal(a, b) {
	if (type(a) != type(b)) return false;
	if (type(a) == 'array') {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++) if (!equal(a[i], b[i])) return false;
		return true;
	}
	if (type(a) == 'object') {
		if (length(keys(a)) != length(keys(b))) return false;
		for (let key, value in a) if (!exists(b, key) || !equal(value, b[key])) return false;
		return true;
	}
	return a == b;
}

export function value_valid(value) {
	return value == null || type(value) == 'string' ||
		type(value) == 'array' && !length(filter(value, v => type(v) != 'string'));
}

export function option_equal(option, a, b) {
	// The firewall UI omits unchecked masquerading flags; fw4 defaults to off.
	let optional = option.config == 'firewall' && option.type == 'zone' && index([ 'masq', 'masq6' ], option.key) >= 0;
	return equal(optional ? a ?? '0' : a, optional ? b ?? '0' : b);
}

export function section_equal(section, a, b) {
	if (type(a) != 'object' || type(b) != 'object') return false;
	for (let key in uniq([ ...keys(a), ...keys(b) ]))
		if (!option_equal({ ...section, key }, a[key], b[key])) return false;
	return true;
}

export function read_snapshot(text, mode) {
	let state;
	try { state = json(text || 'null'); } catch (e) {}
	let valid = s => type(s) == 'object' && index([ 'network', 'dhcp', 'firewall', 'wireless' ], s.config) >= 0 &&
		type(s.sid) == 'string' && length(s.sid) && type(s.type) == 'string' && length(s.type);
	if (state?.version != 1 || index([ 'main', 'sub', 'ap' ], mode) < 0 || state.mode != mode || type(state.subnet_done) != 'bool' ||
		type(state.options) != 'array' || type(state.created) != 'array' || !length(state.options) && !length(state.created))
		die('Mode switch refused: saved configuration snapshot is missing or invalid');
	let seen = {};
	for (let s in state.created) {
		let id = `${s.config}/${s.sid}`;
		if (!valid(s) || type(s.values) != 'object' || seen[id] ||
			length(filter(values(s.values), v => !value_valid(v))))
			die('Mode switch refused: saved configuration snapshot is missing or invalid');
		seen[id] = true;
	}
	for (let o in state.options) {
		let id = `${o.config}/${o.sid}/${o.key}`;
		if (!valid(o) || type(o.key) != 'string' || !length(o.key) || substr(o.key, 0, 1) == '.' ||
			(mode == 'ap' && (!exists(o, 'value') || !value_valid(o.value))) || !exists(o, 'expected') || !value_valid(o.expected) ||
			seen[id] || seen[`${o.config}/${o.sid}`])
			die('Mode switch refused: saved configuration snapshot is missing or invalid');
		seen[id] = true;
	}
	return state;
}

export function check_snapshot(uci, state, wan_trigger) {
	let conflicts = [];
	let configs = {};
	function section(config, sid) {
		if (!exists(configs, config)) configs[config] = uci.get_all(config) || {};
		return configs[config][sid];
	}
	for (let o in state.options) {
		// Changing the WAN protocol is the explicit main/sub mode trigger.
		if (wan_trigger && o.config == 'network' && o.sid == 'wan' && o.key == 'proto') continue;
		let saved = section(o.config, o.sid);
		if (saved?.['.type'] != o.type || !option_equal(o, saved?.[o.key], o.expected))
			push(conflicts, `${o.config}.${o.sid}.${o.key}`);
	}
	for (let s in state.created) {
		let saved = section(s.config, s.sid);
		if (saved?.['.type'] != s.type || !section_equal(s, section_values(saved), s.values))
			push(conflicts, `${s.config}.${s.sid}`);
	}
	if (length(conflicts)) die('Mode switch refused: user changed ' + join(', ', conflicts));
}

export function record_option(uci, state, config, sid, key) {
	if (length(filter(state.created, s => s.config == config && s.sid == sid)) ||
		length(filter(state.options, o => o.config == config && o.sid == sid && o.key == key))) return;
	let option = { config, sid, key, type: uci.get_all(config, sid)?.['.type'] };
	if (state.mode == 'ap') option.value = uci.get(config, sid, key);
	push(state.options, option);
}

export function record_context(uci, state, data) {
	for (let config, sections in data.switch_watch || {})
		for (let sid, options in sections)
			for (let key in options) record_option(uci, state, config, sid, key);
	let bridges = 0;
	uci.foreach('network', 'device', s => {
		if (s.name == uci.get('network', 'lan', 'device') && s.type == 'bridge') {
			bridges++;
			for (let key in [ 'name', 'type', 'ports' ]) record_option(uci, state, 'network', s['.name'], key);
		}
	});
	if (bridges > 1) die('Mode switch refused: ambiguous matching sections in network.device');
	uci.foreach('wireless', 'wifi-iface', s => {
		let networks = type(s.network) == 'array' ? s.network : split(s.network || '', /\s+/);
		if (index([ 'ap', 'ap-wds' ], s.mode) >= 0 && length(filter(networks, n => index([ 'lan', 'wan', 'wan6' ], n) >= 0)))
			record_option(uci, state, 'wireless', s['.name'], 'network');
	});
}

export function finish_snapshot(uci, state) {
	for (let o in state.options) o.expected = uci.get(o.config, o.sid, o.key);
	for (let s in state.created) {
		let section = uci.get_all(s.config, s.sid);
		s.type = section['.type'];
		s.values = section_values(section);
	}
	return sprintf('%J', state);
}
