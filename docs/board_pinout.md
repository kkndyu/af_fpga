# AX7203B pin assignment

Authoritative pin data for this board, and where each number came from.
Never invent a pin number: a wrong assignment does not damage the board, it
just wastes a build cycle and looks like a logic bug.

## Source of each value

| What | Source | Trust |
|---|---|---|
| Clock, reset, LEDs | `docs/ref/alinx_ax7203/led.xdc` and `led_test_io_placed.rpt` (factory LED project) | verified on hardware |
| UART | `uart_test` demo project's own XDC, extracted from `01_demo_document.zip` in the ALINX distribution | not yet used on this board |
| Everything else | not known - no schematic in this repository | do not guess |

The factory LED project and the UART demo agree on the clock, reset and SPI
flash settings, which is a good sign that both target the same board revision.

## Currently constrained (constr/ax7203.xdc)

```
signal       pin   site                    IO standard   note
------------------------------------------------------------------
sys_clk_p    R4    IO_L13P_T2_MRCC_34      DIFF_SSTL15   200 MHz oscillator
sys_clk_n    T4    IO_L13N_T2_MRCC_34      DIFF_SSTL15   P/N of the same pair
rst_n        T6    (LVCMOS15)              LVCMOS15      active low
led[0]       B13   IO_L8N_T1_16            LVCMOS33      active LOW
led[1]       C13   IO_L8P_T1_16            LVCMOS33      active LOW
led[2]       D14   IO_L6P_T0_16            LVCMOS33      active LOW
led[3]       D15   IO_L6N_T0_VREF_16       LVCMOS33      active LOW
```

`sys_clk_n` is consumed by the IBUFDS primitive inside `moe_proto_board.v`, so it
has no separate constraint.

### LED polarity

The factory `led_test.v` drives `4'b1110` to light "LED1", i.e. a `0` bit lights
the LED. All LED logic in this project is written for **active low**.

## Available but not yet used

```
signal       pin   IO standard   note
------------------------------------------------------------------
uart_rx      P20   LVCMOS33      board has an on-board USB-UART bridge
uart_tx      N15   LVCMOS33      ("usb uart define" in the demo XDC)
```

Pin count budget: **7 of 285 bonded IOBs used** (2.46 %), 278 spare.

### On the USB-UART

The demo constraint file labels these two pins `usb uart define`, so the board
carries a USB-to-UART bridge and a plain USB cable presents a COM port to the
host - no external USB-TTL adapter is needed. The bridge chip part number is not
documented anywhere in this repository; the demo only proves that the FPGA pins
are P20 and N15 at LVCMOS33.

### Why the result is not shipped out in parallel

The GEMV result is 256 lanes x 32 bit = 8192 bits. Bringing that to pins would
need 8192 IOBs against 285 available. Even 8 lanes at a time (256 bits) would
consume 256 of the 278 spare pins, and nothing on the board reads those pins, so
widening the interface buys nothing without a reader. The result therefore
leaves through a one-byte-at-a-time window (`result_readout`), and a UART dump
over the two pins above is the practical way to get all 256 values to a host.

## Constraints that are easy to get wrong

- The oscillator is **200 MHz** (`create_clock -period 5.000`). Both the factory
  LED project and the UART demo use 5.000 ns.
- `CFGBVS VCCO` / `CONFIG_VOLTAGE 3.3` and `SPIx4` / `CONFIGRATE 50` match the
  factory bitstream settings and must stay in step with the flash.
- Do not raise `BITSTREAM.CONFIG.CONFIGRATE` casually; it is what the factory
  bitstream uses on this board.
