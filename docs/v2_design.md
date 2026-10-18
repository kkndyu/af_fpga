# V2 design - runtime-loadable GEMV

Goal: turn the current design from *a compute circuit frozen into a bitstream*
into *a device that can be re-run with different data without rebuilding*.

V2 keeps the verified 256-lane integer engine, the FP4 codebook and the
one-tap-per-cycle pipeline exactly as they are.  The only thing that changes is
**where the data comes from**: runtime writes instead of `$readmemh` baked into
the BRAM initial contents.

Priority: this comes before replacing the integer codebook with real FP4 E2M1,
because until data can be loaded at runtime there is nothing to evaluate - every
new test vector would cost a 35-minute rebuild.

---

## 1. Control flow

```
 power-on / bitstream loaded
            |
            v
      +-----------+
      |  IDLE     |  weights_ready = 0
      +-----------+
            | LOAD_WEIGHT frames
            v
      +-----------+
      |  LOAD_W   |  writes the weight BRAMs
      +-----------+
            | last frame acknowledged
            v
      +-----------+   <---------------------------------+
      |  READY    |  weights_ready = 1                  |
      +-----------+                                     |
        |        |                                      |
        |        | LOAD_INPUT frames                    |
        |        v                                      |
        |  +-----------+                                |
        |  |  LOAD_A   |  writes the activation BRAMs   |
        |  +-----------+                                |
        |        |                                      |
        |        | RUN                                  |
        |        v                                      |
        |  +-----------+                                |
        |  |   RUN     |  GEMV, loader locked out       |
        |  +-----------+                                |
        |        | done                                 |
        |        v                                      |
        |  +-----------+                                |
        |  |   OUT     |  streams the result to the host|
        |  +-----------+                                |
        |        |                                      |
        +--------+--------------------------------------+
                 |
                 +--> ERROR (latched, reported by STATUS, cleared by a new command)
```

Two latching rules, and they are the whole point of the split:

- `weights_ready` is a **latched flag**, set once when the last weight frame is
  acknowledged.  It is cleared only by reset.  RUN is refused while it is 0.
- The activation buffer is **overwritten every inference**.  There is no
  "activation_ready" flag; LOAD_INPUT followed by RUN is the contract.

These two have different lifetimes, which is exactly the distinction that makes
model load time and per-inference latency separately measurable.

---

## 2. Module changes

```
rtl/mem/wbank_region.v        + write port,  - $readmemh          [modified]
rtl/core/gemv_engine.v        + weight write port, - INIT params   [modified]
rtl/core/result_readout.v     + rd_start_lane                      [modified]
rtl/top/moe_proto_top.v       pass both write ports through        [modified]
rtl/top/moe_proto_board.v     - act_rom, - S_LOAD; + loader        [modified]
rtl/ctrl/moe_loader.v         NEW  command decoder + FSM
rtl/periph/uart_rx.v          NEW  (ported from the ALINX demo)
rtl/periph/uart_tx.v          NEW  (ported from the ALINX demo)
```

Unchanged on purpose: `fp4_product_gen`, `fp4_select`, `mac_lane`, `mac_region`,
`act_buffer`, `expert_engine`.  The verified datapath is not touched.

---

## 3. Interfaces

### 3.1 `wbank_region` - the only memory change

```verilog
module wbank_region #(
    parameter DEPTH     = `H_DIM,
    parameter ADDR_W    = `H_ADDR_W,
    parameter DATA_W    = `REGION_WCODE_W      // 256 bit = 64 lanes x 4 bit
)(
    input                    clk,

    // runtime load port
    input                    wr_en,
    input      [ADDR_W-1:0]  wr_addr,
    input      [DATA_W-1:0]  wr_data,

    // compute read port
    input                    rd_en,
    input      [ADDR_W-1:0]  rd_addr,
    output reg [DATA_W-1:0]  rd_data
);
    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        if (rd_en) rd_data <= mem[rd_addr];
    end
endmodule
```

Design decisions, and why:

- **Whole 256-bit row per write, not 32-bit slices.**  A partial write
  (`mem[a][bank*32 +: 32] <= d`) forces the synthesiser to infer a byte-enabled
  RAM, which is a fragile inference path and may fall back to LUTs.  A full-width
  write infers the standard simple dual-port RAM: one write port, one read port.
  The loader buffers 32 bytes and commits one row, which costs 256 flip-flops and
  reduces writes from 32,768 to 4,096 - irrelevant next to an 11-second UART load.
- **No `initial` block.**  This is the entire point: the BRAM configures as all
  zeros and is filled only at runtime.
- **No extra BRAM cost.**  RAMB36E1 is simple dual-port (one read, one write,
  independent addresses), so this is free.

### 3.2 `gemv_engine`

```verilog
// new
input                      w_wr_en,
input      [1:0]           w_wr_region,
input      [K_ADDR_W-1:0]  w_wr_addr,
input      [`REGION_WCODE_W-1:0] w_wr_data,
```

Each bank is enabled by its own region decode:

```verilog
wbank_region #(...) u_wbank_r0 (
    .clk(clk),
    .wr_en  (w_wr_en && (w_wr_region == 2'd0)),
    .wr_addr(w_wr_addr),
    .wr_data(w_wr_data),
    .rd_en  (rd_en),
    .rd_addr(k_idx),
    .rd_data(wcode_r0)
);
```

The `INIT_R0..R3` parameters and their `$readmemh` are removed.

### 3.3 `moe_proto_top`

Adds pass-throughs for the weight write port, and exposes a start lane for the
readout:

```verilog
input                      w_wr_en,
input      [1:0]           w_wr_region,
input      [`H_ADDR_W-1:0] w_wr_addr,
input      [`REGION_WCODE_W-1:0] w_wr_data,

input      [`E_ADDR_W-1:0] rd_start_lane,     // new
```

### 3.4 `result_readout` - addressable readout

```verilog
input [`E_ADDR_W-1:0] rd_start_lane,
```

and inside the sequencer, one line changes:

```verilog
if (rd_start) begin
    active   <= 1'b1;
    lane_idx <= rd_start_lane;      // was: {`E_ADDR_W{1'b0}}
    ph       <= 3'd0;
end
```

The stream still runs from `rd_start_lane` to lane 255.  A start offset plus an
implicit end is enough for V2 (the whole result is 1 KiB) and costs two lines.
`mac_lane` is untouched.

### 3.5 `moe_loader` - the new control block

```verilog
module moe_loader (
    input  clk, rst_n,

    // byte interface to uart_rx / uart_tx
    input  [7:0] rx_data,
    input        rx_valid,
    output       tx_valid,
    output [7:0] tx_data,
    input        tx_ready,

    // weight load port
    output reg        w_wr_en,
    output reg [1:0]  w_wr_region,
    output reg [9:0]  w_wr_addr,
    output reg [255:0] w_wr_data,

    // activation load port
    output reg        a_wr_en,
    output reg [9:0]  a_wr_addr,
    output reg [15:0] a_wr_data,

    // engine
    output reg        gemv_start,
    input             gemv_done,
    input             gemv_busy,

    // readout
    output reg        rd_start,
    output reg [7:0]  rd_start_lane,
    input             rd_valid,
    input  [7:0]      rd_lane,
    input  [1:0]      rd_byte,
    input  [7:0]      rd_data,
    input             rd_busy,

    // status
    output reg        weights_ready,
    output reg [7:0]  err_code
);
```

---

## 4. Host protocol

Frame, host to FPGA:

```
 offset  field
 ------  ---------------------------------------------------------------
   0    0xA5            start of frame
   1    command
   2    length[15:8]    payload length in bytes
   3    length[7:0]
   4..  payload
 N+3   CRC-8           over bytes 1..N+2 (command, length, payload)
```

CRC-8 (polynomial 0x07) rather than CRC-16: it only has to *detect* corruption,
and the point of having it at all is to stop a dropped byte from being
misdiagnosed as a compute error.  That is the single most valuable field in the
protocol.

Commands:

| Code | Name | Payload | Meaning |
|---|---|---|---|
| 0x01 | WRITE_W | `[target][addr_hi][addr_lo][nrows-1]` + `nrows x 32` bytes | write nrows of one region's weights |
| 0x02 | WRITE_A | `[addr_hi][addr_lo][nvals-1]` + `nvals x 2` bytes | write activations (broadcast to all 4 regions) |
| 0x03 | RUN | none | start one GEMV; refused if `weights_ready == 0` |
| 0x04 | STATUS | none | reply: `[weights_ready][err][busy][done][0][0][0][0]` |
| 0x05 | READ_OUT | `[lane_start][nlanes-1]` | reply: nlanes x 4 bytes, little endian |

`target` byte for WRITE_W:

```
 bit 7:6   layer   00 = gate, 01 = up, 10 = down
 bit 5:2   reserved (0)
 bit 1:0   region  0..3
```

V2 implements layer = 00 only.  The other two are accepted into the address space
and rejected with `ERR_UNSUPPORTED_LAYER`, so the host API and the shard of the
protocol that addresses them are exercised from day one.

### Address space

```
 weights:  expert(2) x layer(3) x region(4) x 1024 rows x 256 bit
           V2 uses expert 0, layer gate: 4 x 1024 x 32 B = 128 KiB
 activations: 1024 x 16 bit = 2 KiB, written to all four regions at once
 output:      256 x 32 bit = 1 KiB, read back by lane offset
```

The host addresses `expert / layer / offset`; it never sees regions, banks or
BRAM primitives.  This is what allows 256 lanes to become 512, or BRAM to become
DDR, without touching host software.  The `region` field in `target` exists only
because V2 has four physically separate banks; it can become an internal
broadcast later without a protocol change.

### Error codes

| Code | Name | Cause |
|---|---|---|
| 0x00 | OK | |
| 0x01 | ERR_CRC | frame CRC mismatch |
| 0x02 | ERR_NOT_LOADED | RUN before any weight frame |
| 0x03 | ERR_BAD_CMD | unknown command |
| 0x04 | ERR_BAD_ADDR | address or length out of range |
| 0x05 | ERR_UNSUPPORTED_LAYER | layer != gate in V2 |
| 0x06 | ERR_BUSY | command arrived while running |

On any error: latch `err_code`, do not modify memories, answer the next STATUS.
An error must never leave a half-written weight bank that then produces a
plausible but wrong result - so a WRITE_W frame is either committed in full or
aborted before its first row.

---

## 5. Clocking and reset

One clock.  `sys_clk_p/n` (200 MHz) -> IBUFDS -> BUFG -> everything, including the
UART.  `uart_tx` / `uart_rx` derive their bit period from `CLK_FRE = 200`, giving
1736 clocks per bit at 115200.

**No asynchronous FIFO and no clock-domain crossing.**  The byte interface between
`uart_rx` and `moe_loader` is a simple ready/valid handshake in one domain.
Introducing a second clock would be the only reason to add a FIFO, and there is
no such requirement.

`load_conflict` interlock, belt and braces:

```verilog
// The host must not be able to write a bank that the engine is reading.
wire w_wr_gated = w_wr_en && (state == L_LOAD_W);
wire a_wr_gated = a_wr_en && (state == L_LOAD_A);
```

The FSM already guarantees this, but gating the actual write enable means a
sequencing bug degrades into "the write is dropped" rather than "silent
corruption of data being read".

---

## 6. Board top after the change

```
moe_proto_board
  |
  +-- IBUFDS / divider          200 MHz engine clock
  +-- uart_rx (N15? no: P20 is rx, N15 is tx)   pin P20
  +-- uart_tx                                  pin N15
  +-- moe_loader                command decode + FSM
  +-- moe_proto_top             engine + readout + checksum
  +-- LED verdict               still shows the on-chip checksum comparison
```

The self-start sequencer, `act_rom` and the 1024-cycle copy loop are **deleted**.
`GOLDEN_CHECKSUM` and the LED verdict stay: they give an immediate on-board sanity
check without a host attached, and cost almost nothing.

---

## 7. Verification plan

Simulation must not depend on a serial port.  The testbench plays the host's role
by driving the loader's byte interface directly:

```
1. read gate_r0..r3.mem and input.mem in the testbench
2. push them through the same 0xA5 protocol frames the UART would carry
3. send RUN
4. read back READ_OUT and compare all 256 lanes against ref_out.hex
```

This exercises the real load path, the CRC, the FSM and the readout - everything
except the physical UART, which is verified separately by a loopback test.

| Test | Checks |
|---|---|
| `tb_loader` (new) | protocol: good frame, bad CRC, short frame, unknown command |
| `tb_result_readout` (reworked) | full load-then-run, 256 lanes vs `ref_out.hex` |
| `tb_moe_board` (reworked) | same, at board level, plus the LED verdict |
| `tb_uart_loopback` (new) | rx decodes what tx encoded, at 115200 |
| `tb_moe_board_gl` | unchanged in intent: routed netlist still computes |

Regression gate: each of these must be able to return a non-zero exit code on
failure.  Today "pass" means "someone read the log", which is not good enough
once there is a protocol with several failure modes.

---

## 8. Acceptance criteria for V2

1. A fresh bitstream, flashed and powered, computes garbage until loaded - there
   are no non-zero `INIT_*` properties left on any weight or activation BRAM.
   Verifiable with `scripts/check_act_load.tcl` extended to the weight banks.
2. After `LOAD_WEIGHT` x 16 frames and `RUN`, the returned 256 words equal
   `ref_out.hex` exactly.
3. Changing the weight file on the host and reloading produces the matching new
   result **without rebuilding the bitstream**.  This is the acceptance test that
   V2 exists for.
4. `STATUS` reports `weights_ready`, and `RUN` before any load returns
   `ERR_NOT_LOADED` instead of silently computing zeros.
5. A frame with a corrupted byte reports `ERR_CRC` and leaves the memories
   unchanged.
6. Model load time and per-inference latency are measured and reported
   separately.

---

## 9. Open issues and risks

| Issue | Status |
|---|---|
| USB-UART bridge part number unknown | 115200 is safe; trying 1 Mbps needs a measurement |
| 128 KiB over 115200 = 11.4 s | acceptable for V2; raise the baud or use a different interface before evaluating throughput |
| Write port changes BRAM inference | must confirm 32 RAMB36E1 still inferred and no `INIT_*` remain |
| `uart_rx` ported from the ALINX demo | needs a loopback test before trusting it |
| V3 gate->down handoff | the handoff is internal, so no top-level interface change is needed; but the activation buffer will need per-region write ports.  V2 should not design against that. |
| JTAG-to-AXI alternative | rejected for V2: `labtools` is missing on this machine, and it would need AXI infrastructure (2000-5000 extra LUT) |
| LUT/FF growth | expected a few hundred LUT for the loader + ~200 for the uart pair; to be measured |
