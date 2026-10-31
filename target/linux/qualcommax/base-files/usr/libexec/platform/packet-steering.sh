#!/bin/sh

# Set QCA IRQ placement before generic RPS derives its CPU mapping.
# Keep this call one-way: smp_affinity must not reload packet_steering.
/etc/init.d/smp_affinity start || exit $?

flows="$(uci -q get network.@globals[0].steering_flows)"
case "$flows" in
	''|*[!0-9]*) ;;
	*) [ "$flows" -eq 0 ] || set -- -l "$flows" "$@" ;;
esac
/usr/libexec/network/packet-steering.uc "$@"
