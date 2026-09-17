#!/usr/bin/env python3
"""Adapt the in-tree Otto PCS/MDIO providers to the sleeping SPI regmap.

The source files remain shared with the Realtek target. Assert each source
anchor so upstream changes fail the build instead of silently losing a fix.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


for filename in ('mdio-rtl9303.c', 'mdio-rtl9303-serdes.c', 'pcs-rtl9303.c'):
    path = root / filename
    text = path.read_text()
    if filename == 'mdio-rtl9303.c':
        text = replace(text, 'syscon_node_to_regmap(dev->parent->of_node)',
                       'dev_get_regmap(dev->parent, NULL)')
        text = replace(text, 'if (IS_ERR(priv->regmap))\n\t\treturn PTR_ERR(priv->regmap);',
                       'if (!priv->regmap)\n\t\treturn -ENODEV;')
        text = replace(text, '"realtek,rtl9301-mdio"', '"realtek,rtl9303-spi-mdio"')
        text = replace(text, '.name = "mdio-rtl9300"', '.name = "mdio-rtl9303"')
        # Set up routing before mdiobus_register() reads any PHY IDs. Preserve
        # the mappings of unused ports, including the MoCA PHY on SMI bus 0.
        start = text.index('static int rtl9300_mdiobus_init(')
        end = text.index('static int rtl9300_mdiobus_probe_one(', start)
        text = text[:start] + '''static int rtl9300_mdiobus_init(struct rtl9300_mdio_priv *priv)
{
	struct regmap *map = priv->regmap;
	u32 mask = 0, value = 0;
	int port, ret;

	for_each_set_bit(port, priv->valid_ports, MAX_PORTS) {
		unsigned int shift = (port % 6) * 5;
		unsigned int bus = priv->smi_bus[port];

		ret = regmap_update_bits(map, SMI_PORT0_5_ADDR_CTRL + (port / 6) * 4,
					0x1f << shift, priv->smi_addr[port] << shift);
		if (ret)
			return ret;
		shift = (port % 16) * 2;
		ret = regmap_update_bits(map, SMI_PORT0_15_POLLING_SEL + (port / 16) * 4,
					3 << shift, bus << shift);
		if (ret)
			return ret;
		mask |= GLB_CTRL_INTF_SEL(bus);
		if (priv->smi_bus_is_c45[bus])
			value |= GLB_CTRL_INTF_SEL(bus);
	}
	ret = regmap_update_bits(map, SMI_GLB_CTRL, mask, value);
	if (ret)
		return ret;
	/* phylib owns link polling; don't race the switch's hardware poller. */
	return regmap_update_bits(map, 0xca04, priv->valid_ports[0], 0);
}

''' + text[end:]
        anchor = '\tdevice_for_each_child_node_scoped(dev, child) {\n\t\terr = rtl9300_mdiobus_probe_one'
        prefix = '''	device_for_each_child_node_scoped(dev, channel) {
		u32 bus;

		if (fwnode_property_read_u32(channel, "reg", &bus) || bus >= MAX_SMI_BUSSES)
			return -EINVAL;
		fwnode_for_each_child_node_scoped(channel, phy)
			if (fwnode_device_is_compatible(phy, "ethernet-phy-ieee802.3-c45"))
				priv->smi_bus_is_c45[bus] = true;
	}

	err = rtl9300_mdiobus_init(priv);
	if (err)
		return err;

'''
        text = replace(text, anchor, prefix + anchor)
        text = replace(text, '\terr = rtl9300_mdiobus_init(priv);\n\tif (err)\n\t\treturn dev_err_probe(dev, err, "failed to initialise MDIO bus controller\\n");\n', '')
        # Each register access now includes an SPI transfer; use a bounded
        # timeout appropriate for a sleeping controller, not MMIO timings.
        text = text.replace('10, 1000)', '100, 20000)').replace('10, 100)', '100, 20000)')
    else:
        text = replace(text, 'syscon_node_to_regmap(np->parent)',
                       'dev_get_regmap(dev->parent, NULL)')
        text = replace(text, 'if (IS_ERR(ctrl->map))\n\t\treturn PTR_ERR(ctrl->map);',
                       'if (!ctrl->map)\n\t\treturn -ENODEV;')
        text = text.replace('\tstruct device_node *np = pdev->dev.of_node;\n', '')
        if filename == 'mdio-rtl9303-serdes.c':
            text = replace(text, '"realtek,rtl9301-serdes-mdio"', '"realtek,rtl9303-spi-serdes"')
            text = replace(text, '.name = "realtek-otto-serdes-mdio"', '.name = "rtl9303-serdes-mdio"')
            text = replace(text, 'snprintf(bus->id, MII_BUS_ID_SIZE, "realtek-serdes-mdio");',
                           'snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));')
            text = replace(text, '\tregmap_write(ctrl->map, ctrl->cfg->base, op);',
                           '\tret = regmap_write(ctrl->map, ctrl->cfg->base, op);\n\tif (ret)\n\t\treturn ret;')
        else:
            text = replace(text, '"realtek,rtl9301-pcs"', '"realtek,rtl9303-spi-pcs"')
            text = replace(text, '.name = "realtek-otto-pcs"', '.name = "rtl9303-pcs"')
    path.write_text(text)
