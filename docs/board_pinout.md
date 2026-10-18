# AX7203B pin map and peripheral inventory

Authoritative pin data for this board, and where each number came from.
Never invent a pin number: a wrong assignment does not damage the board, it
just wastes a build cycle and looks like a logic bug.

## Source of each value

| What | Source | Trust |
|---|---|---|
| Clock, reset, LEDs | `docs/ref/alinx_ax7203/led.xdc` + `led_test_io_placed.rpt` | verified on hardware |
| UART | `uart_test.zip` -> `uart_test.srcs/constrs_1/new/uart_test.xdc` | official demo, not yet used here |
| Keys | `key_test.zip` -> `constrs_1/new/key.xdc` | official demo |
| SD card (SPI mode) | `sd_test.zip` -> `constrs_1/new/sd_card_test.xdc` | official demo |
| Ethernet x2 (RGMII) | `ethernet_test.zip` -> `eth_test.srcs/constrs_1/new/top.xdc` | official demo |
| DDR3 | `ddr3_test.zip` -> `ddr3/user_design/constraints/ddr3.xdc` | official demo |
| Complete pin table | `04_原理图PCB结构图.zip` -> `AX7203_PIN_Define.xls` | not machine-readable here (OLE2, no Excel COM under the sandbox) |

The demos are shipped by ALINX and are known to build and run on this board, so
their constraints are as good as a schematic for the pins they use.  For pins no
demo touches, the spreadsheet or the schematic PDF is the only source - do not
guess.

All the demo projects come from `D:\BaiduNetdiskDownload\AX7203_2019.1\01_demo_document.zip`.

## Currently constrained (constr/ax7203.xdc) - 7 pins

```
signal       pin   IO standard   note
------------------------------------------------------------------
sys_clk_p    R4    DIFF_SSTL15   200 MHz oscillator
sys_clk_n    T4    DIFF_SSTL15   P/N of the same pair
rst_n        T6    LVCMOS15      active low
led[0]       B13   LVCMOS33      active LOW
led[1]       C13   LVCMOS33      active LOW
led[2]       D14   LVCMOS33      active LOW
led[3]       D15   LVCMOS33      active LOW
```

`sys_clk_n` is consumed by the IBUFDS primitive inside `moe_proto_board.v`, so it
needs no separate constraint.

### LED polarity

The factory `led_test.v` drives `4'b1110` to light "LED1", i.e. a `0` bit lights
the LED. All LED logic in this project is written for **active low**.

## Peripheral inventory

Pin count: **7 of 285 bonded IOBs used (2.46 %), 278 spare.**

| Peripheral | Pins | Signals | Useful for loading weights? |
|---|---|---|---|
| LEDs | 4 | B13 C13 D14 D15 | status only |
| Keys | 2 | J21 E13 | mode select |
| **USB-UART** | **2** | **P20 rx, N15 tx** | **yes - V2 choice** |
| **SD card (SPI)** | **4** | AB12 clk, AA14 ncs, AB11 mosi, AA13 miso | **yes - V3 candidate** |
| Ethernet 1 (RGMII) | 14 | see below | yes, but complex |
| Ethernet 2 (RGMII) | 14 | see below | yes, but complex |
| DDR3 (32-bit) | ~50 | see below | storage, not an input path |
| HDMI in / out | - | not extracted | no |
| PCIe x4 | - | not extracted | yes, but needs a host driver |
| LCD / AD / DA / camera | - | expansion modules | no |

### USB-UART - pins

```
uart_rx   P20   LVCMOS33     FPGA receives
uart_tx   N15   LVCMOS33     FPGA transmits
```

The demo constraint file labels these `usb uart define`, so the board carries a
USB-to-UART bridge and a plain USB cable presents a COM port to the host: **no
external USB-TTL adapter is needed.**

The bridge chip part number is not documented in anything machine-readable here.
`AX7203_PIN_Define.xls` would name it but cannot be opened in this environment,
and the schematic PDF is `AX7203-2018-2-2.pdf`.  **115200 is safe** (it is what
the demo uses); anything faster has to be measured on the bench.

### SD card (SPI mode) - pins

```
sd_dclk   AB12  LVCMOS33     SPI clock
sd_ncs    AA14  LVCMOS33     chip select, active low
sd_mosi   AB11  LVCMOS33     FPGA -> card
sd_miso   AA13  LVCMOS33     card -> FPGA
```

Only 4 pins and about 300x the bandwidth of UART.  Costs an SPI SD protocol
implementation (CMD0/CMD8/CMD17 etc.) plus either a FAT layer or raw sector
access.  Worth considering once a single 128 KiB projection stops being enough.

### Ethernet - pins (two independent RGMII ports)

```
port 1, 14 pins                        port 2, 14 pins
rgmii1_rxd[3:0] C19 C18 B18 A16        rgmii2_rxd[3:0] C17 D19 B20 A20
rgmii1_txd[3:0] A18 A19 D20 C20        rgmii2_txd[3:0] A13 C15 C14 E17
rgmii1_rxc      B17                    rgmii2_rxc      E19
rgmii1_rxctl    A15                    rgmii2_rxctl    F19
rgmii1_txc      E18                    rgmii2_txc      A14
rgmii1_txctl    F18                    rgmii2_txctl    D17
e1_mdc          B16                    e2_mdc          F20
e1_mdio         B15                    e2_mdio         C22
e1_reset        D16                    e2_reset        B22
```

Two PHYs, so 28 pins in total.  Fast (100 Mbps) but needs RGMII DDR timing, a
PHY reset/MDIO bring-up and a UDP or TCP stack.  Far more work than the problem
it solves at this stage.

### DDR3 - pins

32-bit data bus plus 15 address lines, bank address, RAS/CAS/WE, CKE/ODT/CS, DQM,
and four differential DQS pairs and one differential clock.  All SSTL15 except
`ddr3_reset_n` (LVCMOS15, W6).  Full list in the demo's `ddr3.xdc`.

**DDR3 is storage, not an input path.** It matters later, for the real
architecture where the model lives in DDR3 and is streamed into BRAM per layer -
that is what removes the on-chip capacity limit discussed in
`resource_assessment.md`. It requires the MIG IP, which is a different class of
work from everything in this prototype so far.

## What each interface costs for loading

One projection is 1024 x 256 weights x 4 bit = **128 KiB**.
A full expert (gate + up + down) is **384 KiB**.

| Interface | Pins | Practical rate | 128 KiB | 384 KiB |
|---|---|---|---|---|
| UART @115200 | 2 | 11.5 KB/s | 11.1 s | 33 s |
| UART @921600 | 2 | 92 KB/s | 1.4 s | 4.2 s |
| UART @2 Mbaud | 2 | 200 KB/s | 0.64 s | 1.9 s |
| SD card, SPI @25 MHz | 4 | ~3 MB/s | 43 ms | 128 ms |
| Ethernet, 100 Mbps RGMII | 14 | ~11 MB/s | 12 ms | 35 ms |

The UART rows above 115200 are speculative: they depend on the bridge chip, which
is unidentified.

## Why the result is not shipped out in parallel

The GEMV result is 256 lanes x 32 bit = 8192 bits. Bringing that to pins would
need 8192 IOBs against 285 available. Even 8 lanes at a time (256 bits) would
consume 256 of the 278 spare pins, and nothing on the board reads those pins, so
widening the interface buys nothing without a reader. The result therefore leaves
through a one-byte-at-a-time window (`result_readout`), and a UART dump is the
practical way to get all 256 values to a host.

## Constraints that are easy to get wrong

- The oscillator is **200 MHz** (`create_clock -period 5.000`). Both the factory
  LED project and every demo use 5.000 ns.
- `CFGBVS VCCO` / `CONFIG_VOLTAGE 3.3` and `SPIx4` / `CONFIGRATE 50` match the
  factory bitstream settings and must stay in step with the flash.
- `T6` is described as LVCMOS15 in `led_test.xdc` and as LVCMOS33 in
  `key_test.xdc` for the same net. This project follows `led_test` (LVCMOS15),
  which is the one that has been built and run. Do not copy `key_test`'s value.
- Do not raise `BITSTREAM.CONFIG.CONFIGRATE` casually; it is what the factory
  bitstream uses on this board.
