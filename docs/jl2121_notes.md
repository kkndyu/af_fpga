# JL2121 PHY: where the manual is, what we know, what is still a guess

Status: **manual is not publicly downloadable; the register table in this file comes
from a Linux kernel driver patch, not from the vendor datasheet.**
Checked 2026-10-27.

This file exists because the same search was needed twice: the AX7203B's Ethernet
PHY is a JLSemi JL2121, and its register-level documentation is not on the public
web. Everything below is either (a) verified in this repository, (b) taken from a
citable external source, or (c) explicitly marked as unverified.

---

## 1. How to get the real manual

| Channel | Where | State at time of writing | Ask for |
|---|---|---|---|
| JLSemi official design documents | [jlsemi.com/design-documents](https://www.jlsemi.com/design-documents) | Page exists, but every entry is behind **user login**, and the Single Port PHY table lists JL2101C / JL2101DC / JL2201B / JL4201 / JL1111B - **no JL2121** | - |
| JLSemi direct | `info@jlsemi.com`, [online support](https://www.jlsemi.com/messages), [sample request](https://www.jlsemi.com/sample-request) | fastest route, needs an account/contact | datasheet (pinout), **register reference manual**, reference schematic, RGMII delay description, strap-resistor table |
| Distributor | [oneyac product page for JL2121-N040I](https://www.oneyac.com/product/34991343.html) | returned HTTP 503 during this check; page exists | datasheet download, if the distributor is authorised to host it |
| Board vendor (ALINX) | [AX7203 product page](http://www.alinx.com//detail/613), AX7203B user manual (Ethernet chapter) | publicly readable manuals for the same board family | PHY strapping, MDC/MDIO pull-ups, RGMII delay straps, PHY reset wiring |

One ask should cover everything: **the JL2121 is a specific customer part** (it is
not in the public product table), so a datasheet request will be routed to an FAE
rather than served as a download.

Useful second-hand confirmation that the part is what this board carries - ALINX
documents the same combination on a sibling board:

> "The Ethernet PHY chip on the PL end is connected to the IO of BANK35. The
> JL2121 chip supports a 10/100/1000 Mbps network..."
> - [AX7Z035B User Manual](https://esys.ir/images/img_Item/2882/Files/AX7Z035B_User_Manual.pdf)

### Nothing usable is on this disk

| Path | What it actually is |
|---|---|
| `build/docs/gige.pdf` (2.3 MB) | a Chinese Ethernet tutorial (ARP, UDP chapters) - **not** a PHY datasheet |
| `build/vendor/ethernet_test.zip` (125 MB, 1567 entries) | the ALINX Vivado demo project - **contains no PDF or datasheet** |
| whole-disk search for `JL21*`, `datasheet`, `规格书` | no match |

---

## 2. Chip facts

### 2.1 Identity

| Item | Value | Source |
|---|---|---|
| Part | JLSemi (景略半导体) JL2121, single-port Gigabit Ethernet PHY, RGMII | board manual |
| PHY ID (register 2/3) | **0x937c4030** | [LKML jlsemi driver](https://lkml.org/lkml/2026/10/18/8) |
| JL2101 ID, for comparison | 0x937c4032 | same |
| JLSemi vendor prefix | 0x937c4000 | same |

**0x937c4030 is the single most useful number in this file**: reading registers 2
and 3 over MDIO and getting `0x937c` / `0x4030` proves, in one transaction, that
MDC, MDIO, the frame format, the turnaround direction switch and the PHY address
are all correct.

### 2.2 Register map

Accessed through the standard clause-22 two-register interface, with **paged**
registers selected by register `0x1f`.

| Purpose | Page (`reg 0x1f`) | Register | Bits | Notes |
|---|---|---|---|---|
| Page select | - | `0x1f` | - | every paged access writes this first |
| PHY identifier | - | `0x02` / `0x03` | - | 0x937c / 0x4030 |
| BMCR (standard) | - | `0x00` | - | reset, loopback, speed, autoneg |
| BMSR (standard) | - | `0x01` | - | link up, speed advertised |
| ANAR (standard) | - | `0x04` | - | advertisement |
| **EEE enable** | - | `0x19` (PHYCR2) | **bit 5** | driver clears it: "autonomous EEE disable to prevent interoperability packet drops" |
| **RGMII TX delay** | `0xd08` | `0x11` (TXCR) | **bit 8** | |
| **RGMII RX delay** | `0xd08` | `0x15` (RXCR) | **bit 3** | |
| Link status PHYSR | `0xa43` | `0x1a` | bit 3 duplex, `[5:4]` speed (`0x20`=1000, `0x10`=100, `0x00`=10), bit 11 master | more reliable than BMSR for resolved speed |
| Interrupt enable | `0xa42` | `0x12` (INER) | bit 4 link change, bit 7 PME | unused here |
| Interrupt status | - | `0x1d` (INSR) | - | read to clear |
| LED control | `0xd04` | `0x10` (LEDCR) | 5 bits per LED, bit 15 = mode, 3 LEDs | |
| WoL config | `0xd8a` | `0x10` / `0x11` | magic-packet event, reset | unused here |
| WoL MAC address | `0xd8c` | `0x10` / `0x11` / `0x12` | - | unused here |

### 2.3 Interface rules that matter for bring-up

- Clause-22 frame, exactly 64 bits: 32 preamble ones, `01`, opcode (`01` write /
  `10` read), 5 PHY address, 5 register address, 2 turnaround, 16 data.
- **MDC maximum 2.5 MHz**, roughly 50 % duty. This is a clock, not a strobe.
- MDIO **changes on the falling edge of MDC**; the PHY **samples on the rising
  edge**. Setup/hold is therefore set by the duty cycle.
- The bus needs a pull-up (1.5k-10k); idle is therefore a logic 1, which is why a
  dropped leading preamble bit can be invisible.

---

## 3. State of this repository (2026-10-27)

| Module | State | Detail |
|---|---|---|
| `rtl/eth/eth_top.v` | instantiates **only** `u_probe` | `eth_mdio` is **not instantiated anywhere** except `tb_mdio.v` - the design currently *reads* the PHY but does not *configure* it |
| `rtl/eth/eth_phy_probe.v` | wired in | holds PHY in reset, waits, then reads register 2 sweeping MDIO addresses (1 first, then 0, 2..7); latches `probe_valid` / `probe_addr` / `probe_id` |
| `rtl/eth/mdio_rw.v` | vendor `smi_read_write` master | used by the probe because its **read** timing is already proven on this board; `REF_CLK` / `MDC_CLK` are parameters |
| `rtl/eth/eth_mdio.v` | write-only sequencer, **not instantiated** | `PHY_ADDR = 5'd1`, `MDC_HZ = 20 kHz`, writes BMCR three values (0x1900 power-down, 0x1100 wake + autoneg + full duplex, 0x1300 restart autoneg), four frames total |

### 3.1 Why the probe exists

Both this design and the vendor's own prebuilt demo report "no link" on this
board, while the PHY's link LEDs are lit on both ports. The only path between the
PHY and the FPGA is MDIO, so the question "does MDIO work at all" had to be
answered before anything else. `eth_phy_probe` answers it in one run:

| Probe result | Meaning |
|---|---|
| `valid = 1`, `addr = 1`, `id = 0x937c` | MDIO works and the vendor's address 1 was right |
| `valid = 1`, `addr = other`, `id = 0x937c` | MDIO works, **the address was wrong** - this alone would explain why every configuration write was silently lost |
| `valid = 0` | nothing on the bus answers: MDC never toggled, wiring, pull-up, or the PHY is held in reset |

### 3.2 The MDIO defects found so far (all in `eth_mdio.v`)

Recorded because they share one signature: **no error, no warning, the PHY simply
does not react.**

| # | Defect | Consequence |
|---|---|---|
| 1 | register address declared `reg [7:0]` against a 5-bit field | frame became 67 bits into 64 → 3 preamble bits truncated → malformed frame, silently ignored |
| 2 | MDC generated as a 1-in-40 pulse (5 MHz, 2.5 % duty) | MDC is a real clock; 5 ns high time is below any PHY's minimum, and hold after the sampling edge collapsed |
| 3 | bit sequencer off by one (shifted first, then drove `frame[62]`) | the MSB never left the pin, only 63 bits sent; invisible on a scope, fatal to the framer |
| 4 | `div_cnt` 7 bits while `DIV` reached 5000 | counter wrapped at 128 → MDC at 781 kHz instead of 20 kHz |

Defect 4 is the same failure class as `rx_rp + 2'd4` and the `bit_idx [2:0]`
buffer index elsewhere in this project: **a counter narrower than the value it
must reach**. Worth grepping for before the next bring-up.

### 3.3 Still open in the 100 Mb-era sequencer

`docs/gigabit_plan.md` §4 records that frames 2 and 3 arrived shifted by one and
two bits, i.e. the frame-to-frame re-priming accumulated an offset:

```
ANAR  = ffffffff 5092 0101    first frame correct
BMCR1 = fffffffe a104 2603    shifted by 1
BMCR2 = fffffffd 42084c07    shifted by 2
```

The current `eth_mdio.v` primes `mdio_o` with `new_frame[63]` and the shifted
`frame` in `S_WAIT`/`S_GAP`, which *should* fix both the MSB loss and the
accumulation. It has **not been confirmed by a testbench** - `tb_mdio.v` exists
and decodes frames, which is the right place to confirm it.

---

## 4. To verify (in order)

1. **Does the PHY answer MDIO?** Read register 2 and expect `0x937c`; also read
   register 3 for `0x4030`. `probe_valid` / `probe_addr` / `probe_id` already
   carry this out to the top level.
2. **PHY address 0 or 1?** The vendor demo hardcodes `00001`; `eth_mdio.v`
   defaults to 1; older revisions of the board top passed 0. The probe settles it.
3. **Who supplies the RGMII delay?** Page `0xd08`, TXCR bit 8 and RXCR bit 3. On
   gigabit RGMII the TX clock/data phase and the RX sampling window must differ by
   roughly 2 ns - supplied by the PHY, or by the FPGA (ODDR phase / IDDR delay),
   **never both and never neither**. This is the classic gigabit blocker.
4. **EEE off?** Clear `0x19` bit 5. The upstream driver does this specifically to
   avoid interoperability packet drops, which matches an "ARP works sometimes"
   symptom better than a dead link.
5. **Board-level strapping**: MDIO pull-up value, PHY reset polarity and timing,
   LED polarity, and whether the RGMII delay is strapped by resistors at
   power-on.

---

## 5. Next steps, cheapest first

| # | Action | Cost |
|---|---|---|
| 1 | Expose `probe_valid` / `probe_addr` / `probe_id` on the board LEDs or a loader STATUS byte | minutes, no new RTL logic |
| 2 | Add register 3 to the probe so the full `0x937c4030` is compared, not just the high half | small |
| 3 | Instantiate `eth_mdio` again once the address is known, with `PHY_ADDR` from the probe | small |
| 4 | Read BMSR (reg 1) and PHYSR (page `0xa43` reg `0x1a`) to get resolved speed/duplex independently of the link LEDs | small |
| 5 | Decide and write the RGMII delay configuration | needs the manual or a scope |

---

## 6. Sources

- [LKML: [PATCH net-next v2] net: phy: Add JLSemi JL21xx Gigabit Ethernet PHY driver](https://lkml.org/lkml/2026/10/18/8)
  - the register map in §2.2 comes from this patch
- [JLSemi design documents](https://www.jlsemi.com/design-documents) (login required)
- [JLSemi product overview](https://www.jlsemi.com/chanpin) - JL2xx1 described as single-port gigabit, RGMII/SGMII
- [ALINX AX7Z035B User Manual](https://esys.ir/images/img_Item/2882/Files/AX7Z035B_User_Manual.pdf) - same PHY documented on a sibling board
- [ALINX AX7203 product page](http://www.alinx.com//detail/613)
- Local: `docs/gigabit_plan.md`, `rtl/eth/eth_mdio.v`, `rtl/eth/eth_phy_probe.v`, `rtl/eth/mdio_rw.v`

---

## 7. What in this file is not certain

Be explicit, so nobody builds on a guess:

- **The register table is driver-derived, not datasheet-derived.** The patch is a
  proposal ("v2") and may still change. Register addresses are corroborated by a
  driver that runs on real hardware; bit-level meanings, page numbers and reset
  values are not.
- **The RGMII delay bits are treated as on/off in the driver.** Whether they only
  enable a fixed delay, or select among several, is unknown without the manual.
- **Default EEE state is unknown** - only that the driver turns it off.
- **JL2121 does not appear in the vendor's public product table**, so its exact
  relationship to JL2101 (same die, different package/strap?) is an assumption
  based on shared register semantics.
