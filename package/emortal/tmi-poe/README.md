# Xiaomi TMI PoE control

`tmi-poe` controls the TMI7604R on Xiaomi P5 and the TMI7608R on Xiaomi P8.
It uses the board's QUP I2C controller and the named `poe-reset` GPIO. The
controller is matched by its device-tree node under `/sys/bus/i2c/devices`;
the I2C adapter number is not assumed to be zero.

`/etc/init.d/tmi-poe` starts the service at boot. Startup resets the PSE,
programs and verifies its configuration, then enables automatic af/at and
Class4+ PD detection and classification. It does not force power onto an
undetected device. Chip overcurrent, disconnect and thermal protection remain
in control of the powered ports; the driver does not override classification
current limits to make a PD draw more power.
Stopping the service shuts down all PoE outputs. Reloading a changed power
budget or Class4+ setting briefly shuts down outputs while updating it.

The chip datasheets describe IEEE 802.3af/at and a proprietary Class4+
extension, with up to 50 W advertised for the chip under the latter mode.
They do not claim IEEE 802.3bt support. Compatibility with a bt PD depends on
that PD's fallback/extension behavior; successful boot alone does not validate
bt negotiation or the PD's maximum rated load.

## Power budget

`/etc/config/tmi-poe` accepts `enabled`, `budget_mw`, `class4plus`, and a list of
`disabled_ports` (`lan1`, `lan2`, etc.). WAN is never a PoE output.
If `budget_mw` is omitted, the original board budget is used:

| Board | Original supply | Board PoE budget |
| --- | --- | --- |
| P5 | 53 V / 1.25 A | 60,000 mW |
| P8 | 53 V / 2.3 A | 105,000 mW |

The supply ratings were provided for these Xiaomi devices. A smaller
replacement supply needs a lower explicit budget, allowing for the router's
own consumption and conversion losses. For P8 powered by the P5 supply,
30,000 mW is a conservative starting configuration used in the LAN2/C360
test; that test did not validate a continuous 30 W or multiport load.

```sh
uci set tmi-poe.main.budget_mw='30000'
uci commit tmi-poe
/etc/init.d/tmi-poe reload
```

Both supplies have the same nominal voltage. The PSE cannot identify the
adapter's rated current from its input-voltage reading. Its port readings
estimate PoE load, not total router input power or the supply's rated maximum.
No automatic adapter-rating detection is implemented.

`class4plus` defaults to `1`, including upgrades retaining the original UCI
file without this option. Set it to `0` only when restricting the controller
to standard af/at operation. No manual or semiautomatic control is needed.

## Diagnostics

`tmi-poe status` reads hardware without resetting it or enabling outputs.
The shared controller lock prevents it from observing a service's partial
configuration update. It reports:

- `requested-mask` / `requested-budget-mw`: the current UCI configuration.
- `hw-budget-raw`: the actual threshold register value; `hw-budget-nominal-mw`
  converts it using the factory nominal 53 V encoding, including quantization.
- `hw-detect` / `hw-classify` / `hw-class4plus` and each port's `mode`:
  hardware configuration.
- `powered` / `good`, detection/classification state, voltage and current:
  controller telemetry. Measurements have not been externally calibrated.

For ports with Class4+ enabled, current telemetry reports the raw ADC code
and both documented scales (`current-ma-at-1a`, `current-ma-at-2a`). The PDFs
specify 1.956 and 3.912 mA/LSB but omit the active-range status encoding.
Enabling Class4+ does not prove a particular PD was classified as Class4+;
the utility therefore labels the current scale unresolved and avoids a
misleading single current/power figure. This affects telemetry, not the chip's
automatic classification or hardware protection.

Requested settings can differ from hardware when a service failed to start,
is stopped, or has not reloaded changed UCI settings. `mode=shutdown` and
`powered=0 good=0` describe an off port even when `requested=1`.

Logs include initialization, bus selection, reset, completed configuration,
port/PGOOD transitions, changed hardware configuration, failures and shutdown.
Bus failures identify the stage, board, address, device-tree node, adapter
directory and selected device. Register verification failures include the
expected and actual bytes. Normal operation logs changes, not every sample.

The P5/P8 reset pin's electrical defaults are applied with the I2C device's
pinctrl state after the TLMM provider has registered its functions. The
current kernel marks `gpio` as a GPIO function, allowing the userspace line
request while retaining the pin's 8 mA drive and pull-up configuration.
