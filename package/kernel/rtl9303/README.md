# CR1000A external RTL9303

Experimental SPI-managed DSA support for the three RJ45 LAN ports. This is
a new data path and requires hardware validation before production use.

| Interface | MAC | PHY management | PCS |
| --- | --- | --- | --- |
| lan1, 10G | RTL9303 port 8 | SMI 2, address 0, AQR113C | SerDes 3, USXGMII |
| lan2, 2.5G | RTL9303 port 20 | SMI 0, address 7, RTL8221B | SerDes 5, 2500BASE-X |
| lan3, 2.5G | RTL9303 port 24 | SMI 1, address 3, RTL8221B | SerDes 6, 2500BASE-X |
| CPU uplink | RTL9303 port 27 ↔ IPQ port 5 | fixed 10G | SerDes 9, 10GBASE-R |
| wan | IPQ port 6 | IPQ MDIO address 8, AQR113C | USXGMII |

The two 2.5G socket labels still need comparison against the enclosure.
The OEM profile uses the RTL8226B name for the RTL8221B PHY family; Linux
detects the PHY ID and uses its existing Realtek driver. The Aquantia driver
is likewise reused unchanged. Only the external switch needs a new driver.

SPI uses the IPQ QUP controller, GPIO 5–8, chip select 0 and 12 MHz. A register
read is one 8-byte transfer: `03 addr_hi addr_lo 00 00 00 00 00`, with a
big-endian value in receive bytes 4–7. A write is
`02 addr_hi addr_lo 00 value_be32`. These match the OEM `ioal_mem32_*`
implementation. `spi-realtek-rtl.c` controls the RTL838x/839x internal SPI
controller and cannot manage this external chip from the IPQ.

The package adapts the tree's RTL9300 MDIO, Otto SerDes MDIO and Otto PCS
providers to a sleeping parent SPI regmap. MDIO routing is installed before
PHY enumeration. Probing waits for the LAN PHYs and PCS providers; SerDes
initialization and PHY negotiation need no userspace SDK commands. No PHY
firmware is included or requested through DT. Both PHY families use the
upstream drivers and the firmware already running on the board. Any extra
PHY initialization will be considered only after hardware testing.

The known-working IPQ uplink and OEM DTS use 10GBASE-R, despite some board
descriptions calling it USXGMII. The fixed 10G speed belongs to `lan-cpu`;
each new LAN netdev obtains its actual cable speed from its own PHY.

Port 27 is a regular switch MAC, not the internal CPU port 28. RX uses
`0xe00 | (switch_index << 5) | port` as an outer 802.1ad service VID to
preserve ingress identity, including five port bits for ports 20 and 24.
Customer tags remain opaque inside the service tag. Do not expose or
configure the private `lan-cpu` transport as a LAN socket.

The default VLAN-unaware LAN bridge now offloads unicast and broadcast to
RTL9303. RX VLANs for members of one bridge share a unicast FID (49–51),
while different bridges and standalone ports remain isolated. The ASIC
learns source MACs and ages dynamic entries. Linux programs static/host
FDB entries; assisted learning covers hosts behind Wi-Fi or other software
bridge ports. `bridge fdb show dev lan1` can dump the hardware table over
SPI, which is slower than normal traffic. SPI is only a management path.

CPU transmission uses a separate private TX VID,
`0xf00 | (switch_index << 5) | port`, with one user member and learning
disabled. This ensures each Linux-directed frame exits exactly one socket,
even if its destination is broadcast or is learned on another port in the
bridge. Received hardware-forwarded unicast/broadcast copies carry the DSA
forwarding mark so Linux does not send a duplicate back to the same switch.
Known LAN-to-LAN unicast stays within RTL9303 after learning.

Multicast uses the RX VLAN profile to reach only the external CPU; Linux
performs multicast snooping and replication, including IPTV/IGMP/MLD.
It is deliberately not marked as already forwarded. STP and port isolation
control the hardware port matrix in both directions. CPU delivery stays
available on blocked ports so BPDUs can reach Linux; no traps use the
unconnected internal CPU. Link-down/bridge changes flush dynamic entries.
Bridge table changes stop user MACs until a complete configuration is
installed; failed joins/flag changes attempt rollback and report SPI errors.

A bridge **created with VLAN filtering already enabled** falls back to
software. Turning filtering on while its ports are hardware-offloaded is
rejected with an explanatory error; recreate that bridge with filtering
enabled. Likewise, a bridge with unicast/broadcast flooding disabled or
hairpin/locked ports uses software from join. Changing those unsupported
settings on an already offloaded bridge is rejected. Multicast-flood,
learning and isolated-port flags are supported. This avoids claiming VLAN,
locked-port or hairpin offload that the private transport cannot enforce.

No PHY firmware loader, NAT/PPE flow acceleration, hardware multicast
replication, or full VLAN-aware bridge offload is added. The initial probe
cleans only reserved FDB domains in SRAM/CAM to handle warm reloads; it may
take additional time over SPI. FDB bucket hashing and register fields were
checked against OpenWrt rtl930x and the statically inspected OEM SDK.

Only ports 8, 20, 24 and 27 are configured. The driver does not reset the
whole switch or initialize MoCA port 25. Default networking is three LANs
and one WAN. An initial-boot UCI migration expands old `lan` bridge members
(including VLAN suffixes and bridge VLAN flags) and direct `device=lan`
attachments while retaining IP, DHCP, firewall and MAC settings.

Sources:

- https://docs.kernel.org/networking/dsa/dsa.html
- https://github.com/openwrt/openwrt/tree/main/target/linux/realtek
- https://github.com/torvalds/linux/blob/v6.18/drivers/net/mdio/mdio-realtek-rtl9300.c
- https://github.com/torvalds/linux/tree/v6.18/drivers/net/phy/aquantia
- https://github.com/Xilinx/linux-xlnx/blob/master/drivers/spi/spi-realtek-rtl.c
- https://github.com/2theo2blau/cr1000a/tree/9bf7af170324879bbc47ff6968150be47aed5612
- https://github.com/MeisterLone/Verizon-CR1000A/tree/1a0748ddeb8b833dd691d7ead35036a40ed3ea36

Remaining hardware checks: cold boot and warm reboot, insertion/removal on
all three sockets, 100M/1G/2.5G/10G negotiation as supported by each PHY,
bidirectional traffic, MAC learning/moves/ageing, broadcast duplicate counts,
multicast snooping, STP blocking, VLAN-tagged traffic, bridge isolation, saved-config
upgrade and WAN operation. A successful cross-compile cannot establish
these results.
