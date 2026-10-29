/* SPDX-License-Identifier: GPL-2.0-or-later OR MIT */
/* The Qualcomm EDMA conduit and the PPE switch behind it. */

#ifndef __LINUX_QCA_EDMA_H
#define __LINUX_QCA_EDMA_H

#include <linux/netdevice.h>

struct dsa_switch;
struct qca_ppe_wifi_inject_ops;

/**
 * struct qca_edma_switch_ops - what the switch behind the conduit provides
 * @flow_xmit: send on a frame the switch routed to the CPU port on flow
 *	@flow, finished; returns false to leave it to the receive path
 * @wifi_ingress_return: restore an exception from a private WLAN ingress
 * @wifi_xmit: consume a verified WLAN service-code frame
 * @wifi_register: publish the ready conduit to WLAN ingress producers
 * @wifi_unregister: unpublish it and wait for selected producers to finish
 */
struct qca_edma_switch_ops {
	bool (*flow_xmit)(struct dsa_switch *ds, struct sk_buff *skb, u32 flow);
	bool (*wifi_ingress_return)(struct sk_buff *skb, u8 port);
	void (*wifi_xmit)(struct sk_buff *skb, u8 port);
	void (*wifi_register)(const struct qca_ppe_wifi_inject_ops *ops);
	void (*wifi_unregister)(const struct qca_ppe_wifi_inject_ops *ops);
};

int qca_edma_switch_register(struct net_device *conduit, struct dsa_switch *ds,
			     const struct qca_edma_switch_ops *ops);
void qca_edma_switch_unregister(struct net_device *conduit);
netdev_tx_t qca_edma_port_xmit(struct sk_buff *skb, struct net_device *conduit,
			       unsigned int port);

#endif
