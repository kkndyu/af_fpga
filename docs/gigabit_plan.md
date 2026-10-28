# Gigabit RGMII: what the vendor demo settled, and what is left

Status: **design decided, ground work in place, integration not started.**

The 100 Mb path is complete and simulated (see `jtag_axi_findings.md` for the
build side) but does not link: the PHY negotiates 1000 Mb and ignores the
restricted advertisement. The decision was taken to follow the vendor demo and go
gigabit instead of continuing to fight the PHY down to 100 Mb.

---

## 1. What the vendor demo proved, and where it lives

Everything below came from `AX7203_2019.1/01_demo_document.zip`, which was never
unpacked before this point. Every one of these facts had been guessed at during
several failed debug cycles, and every guess was wrong.

```
01_demo_document/demo/ethernet_test.zip
  ethernet_test/eth_test.srcs/constrs_1/new/top.xdc
  ethernet_test/eth_test.srcs/sources_1/mdio/mdio_com.v
  ethernet_test/eth_test.srcs/sources_1/mdio/phy_reg_config.v
  ethernet_test/eth_test.srcs/sources_1/imports/src/util_gmii_to_rgmii.v
```

### 1.1 Pin bit order - was reversed

```tcl
set_property PACKAGE_PIN C19 [get_ports {rgmii1_rxd[3]}]     # C19 is bit 3
set_property PACKAGE_PIN A16 [get_ports {rgmii1_rxd[0]}]     # A16 is bit 0
set_property PACKAGE_PIN A18 [get_ports {rgmii1_txd[3]}]
set_property PACKAGE_PIN C20 [get_ports {rgmii1_txd[0]}]
```

This project had it the other way round, so every received and transmitted nibble
was bit-reversed. Nothing reports an error: frames arrive, checks fail, and the
parser rejects them. Fixed in `constr/ax7203_eth.xdc`.

### 1.2 PHY MDIO address - was 0, is 1

`mdio_com.v` drives the address field as `00001`. Writing to address 0 lands on
nothing, and the PHY therefore keeps its power-on configuration, which is
auto-negotiate everything, which lands on 1000 Mb. Fixed in `eth_mdio.v`.

### 1.3 PHY configuration sequence

`phy_reg_config.v` writes **only register 0**, three times:

```
0x1900   power down, auto-negotiation enabled, full duplex
0x1100   wake up, auto-negotiation enabled, full duplex
0x1300   same, plus restart auto-negotiation
```

Note that **the vendor does not restrict the speed at all**. Their demo runs at
1000 Mb. There is no evidence anywhere in the demo that this PHY will accept a
100 Mb-only advertisement, which is the reason the 100 Mb path was abandoned.

### 1.4 Clock relationship - no MMCM needed

In the 7-series version of the converter:

```verilog
assign gmii_tx_clk_s = gmii_rx_clk;      // transmit clock IS the receive clock
assign gmii_tx_clk   = gmii_tx_clk_s;
```

So the GMII side is a **single 125 MHz domain derived from the PHY's RX_CLK**.
Nothing has to be generated. This is the single most useful fact for the
integration: an earlier plan called for an MMCM to make 125 MHz from 200 MHz, and
that is not necessary.

### 1.5 Two copies of the converter exist, only one is usable

| path | primitives | verdict |
|---|---|---|
| `src/util_gmii_to_rgmii.v` | ODDR2, IDDR2, ODDR, IDDR | **Spartan-6 era; ODDR2 is not a 7-series primitive** |
| `sources_1/imports/src/util_gmii_to_rgmii.v` | ODDR, IDDR, BUFG only | **this one** |

The usable copy is `rtl/eth/util_gmii_to_rgmii.v` (260 lines). It compiles.

---

## 2. Target architecture

```
                   125 MHz domain                    200 MHz domain
                 (PHY RX_CLK)                       (fabric)
  ┌──────────┐   gmii_rxd[7:0]  ┌──────────┐      ┌──────────────┐
  │ util_gmii│────────────────►│ eth_gmii │─────►│              │
  │ to_rgmii │   gmii_rx_dv     │   _rx    │ FIFO │ eth_udp_stack│
  │          │◄────────────────│          │◄─────│              │
  └──────────┘   gmii_txd[7:0]  └──────────┘      └──────────────┘
      ▲          gmii_tx_en        eth_gmii_tx
      │
   RGMII pins
```

`speed_selection = 2'b10` (gigabit), `duplex_mode = 1'b1`.

The existing `eth_udp_stack.v` is kept unchanged: it is the only part of the
Ethernet work that is fully tested (`tb_eth`, `tb_rgmii` both pass) and it does
not care what the bytes come from.

---

## 3. Work items

| # | item | notes |
|---|---|---|
| 1 | `util_gmii_to_rgmii.v` in the project | **done**, compiles |
| 2 | `eth_gmii_rx.v` | gmii byte stream @125 MHz, strip preamble, hunt for the 0xD5 delimiter, emit aligned bytes with a start-of-frame flag. This is the logic already proven in `eth_rgmii_rx.v`, minus the oversampling. |
| 3 | `eth_gmii_tx.v` | bytes @125 MHz, add preamble + SFD + FCS, drive `gmii_txd`/`gmii_tx_en`. Adapts `eth_rgmii_tx.v`, which already computes CRC-32. |
| 4 | `eth_async_fifo.v` | **was deleted** when the design was simplified to a single clock domain. Two instances needed, one per direction. The 9th bit carries the start-of-frame flag. |
| 5 | `eth_top.v` rewrite | instantiate the converter, both FIFOs, both GMII adapters, keep the MDIO block and the loader interfaces |
| 6 | `eth_mdio.v` | switch to an unrestricted advertisement (the vendor values) since the link is now gigabit; the 100 Mb advertisement and the ANAR selector bug become moot |
| 7 | `constr/ax7203_eth.xdc` | add `create_clock -period 8.000 [get_ports rgmii_rxc]` as the vendor demo does, and remove any 100 Mb assumption |
| 8 | `tb_rgmii.v` | rewrite the PHY model for DDR: drive a different nibble on each edge |
| 9 | delete `eth_rgmii_rx.v`, `eth_rgmii_tx.v` | superseded |

### Not needed, contrary to the earlier plan

- **No MMCM.** 125 MHz comes from the PHY.
- No change to `eth_udp_stack.v`.
- No change to the loader or the arbitration.

---

## 4. What is still broken in the 100 Mb path, for the record

`eth_mdio.v` sends three frames. Simulation (`tb_mdio.v`) shows the first frame
correct bit for bit:

```
ANAR = ffffffff50920101   preamble ok, start 01, opcode 01, addr 1, reg 4,
                          turnaround 10, data 0101
```

but the second and third arrive shifted by one bit, and the shift accumulates:

```
BMCR1 = fffffffe a1042603
BMCR2 = fffffffd 42084c07
```

So the frame framer is correct and the frame-to-frame re-priming is not. This
stops mattering once the link is gigabit, but it is worth fixing rather than
deleting, because the same sequencer will be needed if the PHY is ever forced to
100 Mb for a different bring-up.
