# Wireless patch responsibilities

Keep the standard PatchDir order: build, subsys, common ath, individual ath
drivers and the remaining vendors. Kernel-version-labelled backports retain
exact filenames/content, including the Raspberry Pi 6.12 series. The build
unaligned-header backport also retains its Linux 6.12 source reference.

| Area | Responsibilities |
| --- | --- |
| cfg80211/mac80211 | MLO station dumps, rates, DFS, AQL, four-address links |
| AP/MLD state | Reconfiguration, active-link lifetime, per-link statistics |
| Common ath | Debug/build interfaces remain separate from regulatory policy |
| ath11k platform | QCN6122 capabilities/bus support and firmware recovery |
| ath11k performance | Ring selection, TXQ/AQL, RX ownership, TX batching |
| ath11k resources | BH scheduling and indexed TX buffer ownership |
| ath12k platform | HW1 compatibility, DT identity and memory resources |
| ath12k MLO | Peer links/IDs, firmware ABI, MAC restart, UserPD/rootPD recovery |
| ath12k datapath | WMI bounds, monitor decoding, statistics, TX status lifetime |
| ath12k Direct Switch | Complete native DMA/transport and buffer ownership |

Do not merge unrelated MAC operations, firmware memory and peer recovery into
one whole-file patch. Preserve complete functional units and combine their
consecutive repairs without intermediate enable/revert implementations.
Other vendor or compatibility patches remain independent where there is no
coherent function to combine.

ath11k 992 retains six consecutive responsibilities: ring selection, TXQ/AQL,
RX buffers, TX/TCL batching, BH scheduling and TX index lookup. Collapsed
single-member series such as ath11k 955 and ath12k 100/906 drop subindices.
Version-labelled series stay unchanged. Shared driver contracts precede their
consumers; native Direct Switch requires the matching kernel PPE interfaces.
Always validate forward/reverse replay and the final expanded source.

Use the upstream 007 IEEE80211 forward-path discovery and 108 compact DMA
capability parser once each. Bridge and routed flowtables request the upstream
IEEE80211 terminal path; ath11k/ath12k do not duplicate it with AP-only callbacks.
PPDU limits remain separate. The sole PPDU-limit and 394 management-link units
have no series subindex.
