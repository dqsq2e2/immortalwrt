# Qualcomm AX patch responsibilities

Keep kernel-version-labelled backports unchanged, including their filenames,
headers, hunks and order. Other changes are organized by functional purpose,
not by collecting every modification to one source file or SoC.

| Area | Responsibilities |
| --- | --- |
| Platform resources | Firmware memory, secure WLAN, CPU frequency/cooling |
| USB and PHY | DWC3 reference clocks/layout, IPQ5018 combo USB3 PHY |
| Clocking | Ethernet parents, GMAC/UNIPHY reset, essential fabric clocks |
| Firmware | SCM services, MDT loading, secure WCSS startup, multi-PD ownership |
| Peripherals | Pin control, NAND IDs/ECC, APM, CPR and boot command line |
| Networking | Driver registration, QCA ethertype, 8021Q domains, VLAN uppers |

USB controller layout is separate from Ethernet parent clocks. Secure WCSS,
multi-PD contexts and firmware-loading APIs retain distinct ownership.
Existing complete APM/CPR implementations remain individual driver units.

AX PPE/EDMA implementation and its dedicated matrix snapshot live in the
standard target overlay. Kernel patches provide driver registration and
network framework integration. No additional patch loader is used.

Only consecutive changes with a coherent function are combined, generated
from their exact application point. Keep kernel-version backports outside
those units. Remove a redundant series suffix when only one member remains;
remaining series members use consecutive suffixes. Preserve the primary
numeric application prefix and validate the full replay result.

PPE (0952) and EDMA (0953) registration remain separate to follow upstream
driver updates. Common flowtable/FDB/VLAN interfaces are owned by generic;
platform patches provide only their hardware consumers.
