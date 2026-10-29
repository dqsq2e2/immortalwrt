# Qualcomm BE patch responsibilities

Preserve explicit kernel-version backports verbatim. The secure WCSS PIL
backport (2010-01) also retains its original implementation and metadata.
Organize other patches by function, retaining the standard lexical loader.

| Area | Responsibilities |
| --- | --- |
| PHY/PCS | QCA8084 package, SerDes lifecycle, PCS modes/bring-up |
| EDMA | Controller, netdev ports, RX, TX, interrupts, statistics, tuning |
| Platform | Clocks, reset/power domains, MDIO initialization, DTS resources |
| L2 | Bridge membership, VLAN domains, FDB, multicast, flooding |
| L3 | Hardware tables, flowtable lifetime, IPv6, PPPoE, VLAN transport |
| Tunnels | Transactions, IPv4-over-IPv6, MAP-E, underlay/LWT resolution |
| VP | Allocation/events, flow delivery, ingress, redirects, uplink lifetime |
| Ownership | Indexed flow readback, topology lifetime, DS rings/producers |

Do not combine controller allocation with netdev lifetime, queue limits with
interrupt mitigation, or flow priority with shaper state merely because they
share a driver. Native PPE remains patched in the kernel source tree.
Dedicated failure handling and diagnostics belong with the relevant function.

Merged patches retain their first primary ordering number. A collapsed series
has no orphan -01 suffix; multi-member series are numbered consecutively.
Preserved version backports are exempt from renaming. Generate each unit at
its precise application point and verify both directions and final source.

The 2010 series keeps the versioned PIL base unchanged, followed by distinct
Q6 crash acknowledgements, UserPD boot metadata and auxiliary firmware units.
Shared framework changes live in generic and are not duplicated here.
