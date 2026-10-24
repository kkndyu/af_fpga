# Postmortem: the weight-readback change that cost two hours of place-and-route

Written while the detail is still fresh. This is the one change in the V2 project
that made the build pathologically slow without adding any logic worth speaking
of, and it is worth understanding because the same mistake is easy to repeat.

## Summary

Adding the weight-readback feature moved `route_design` from **499 s to over two
hours**, and the design never finished routing in the attempts made. Resource use
was essentially unchanged: **-114 LUT and -141 FF** versus the last good build.

The cost was entirely in the shape of the connectivity.

## What was built

`rtl/ctrl/weight_readback.v`: a small module that takes over the weight banks'
read port while the engine is idle, captures one 256-bit row, and serialises it
into bytes for the reply FIFO. About 200 flip-flops and a few dozen LUTs.

It was instantiated **inside `moe_loader`**, because that is where the reply FIFO
lives.

That single placement decision required this path:

```
wbank_r0..r3  (four banks, spread across the die, one per 64-lane region)
     |
     |  256-bit 4:1 mux
     v
gemv_engine -> expert_engine -> moe_proto_top -> moe_proto_board -> moe_loader
                                                                      |
                                                               weight_readback
```

## Why it was so expensive

### 1. Every bank output gained a second, far-away load

`wcode_r0` previously fed only `u_region0`, which is next to it. That locality is
deliberate - `mac_region.v` carries a long comment about the `keep_hierarchy` and
`dont_touch` attributes that exist purely to stop the tool from pooling those
registers across regions.

Now the same 256-bit value also had to reach a 4:1 mux and then travel four module
boundaries. Four banks x 256 bits = **1024 nets dragged across the die**.

### 2. The bank read address stopped being local

```verilog
wire [K_ADDR_W-1:0] bank_rd_addr = rb_en ? rb_addr : k_idx;
```

`k_idx` was an engine-local register sitting beside the banks. `rb_addr` comes from
the loader, on the far side of the die, and fans out to **4 banks x 8 RAMB = 32
address ports**.

### 3. It compromised the placement of the whole design, not just that path

The loader is already the critical-path module: in the preceding build the worst
setup path was

```
u_loader/cmd_reg[4]  ->  u_loader/fifo_reg[5][3]
```

Adding a 256-bit input forced the placer to put the loader at the centroid of the
four bank regions - while it simultaneously has to stay near the AXI bridge, the
UART, and the rest of its own logic. Those requirements conflict, so the placer
compromised, and everything else got harder to route too.

**That is why the whole build slowed down, not just one path.** A wide bus is not a
local problem; it is a global placement constraint.

## The evidence that pointed at connectivity, not logic

| | Last good build (`4C2448B8`) | Broken build | Delta |
|---|---|---|---|
| Slice LUTs | 37,371 | 37,257 | **-114** |
| Slice Registers | 21,856 | 21,715 | **-141** |
| Block RAM | 34.5 | 34.5 | 0 |
| DSP | 0 | 0 | 0 |
| `route_design` | **499 s** | **> 7200 s, unfinished** | ~15x |

The design got *smaller* and the routing got *15x slower*. Resources were never a
plausible explanation.

For scale: adding `jtag_axi` plus the entire `dbg_hub` - tens of thousands of logic
cells and extra BRAM - cost **zero** additional routing time (499 s before and
after), because those connections are local and directional.

## The fix

Move the serialiser **into `gemv_engine`**, next to `wcode_r0..r3`. The 256-bit row
then never leaves the module, and the external interface becomes:

```
down: rb_start (1) + rb_region (2) + rb_addr (10) + rb_nrows (16) + rb_byte_ready (1)
up:   rb_byte_out (8) + rb_byte_valid (1) + rb_done (1)
```

**~1024 wide nets -> 40 narrow ones.** `weight_readback.v` itself was not modified;
only where it is instantiated.

Verified after the move:

```
LOADER TB: weight readback: region 0, rows 0..3
LOADER TB:   readback byte count = 128 (expect 128)
LOADER TB:   readback matches gate_r0.mem exactly
LOADER TB: PROTOCOL TESTS PASSED
```

## Lessons

**The cost of a change is the shape of its connectivity, not the size of its
logic.** A 200-flop addition can be far more expensive than a 20,000-cell IP. Before
committing to a 30-minute build, ask where the new wide buses run and how many
module boundaries they cross.

**Wide buses are global placement constraints.** 256 bits leaving a module is not
"one more port"; it is a magnet pulling that module and everything it connects to.

**Do not use a resource report as a proxy for build cost.** Here they moved in the
opposite direction to the thing that actually mattered.

**Incremental builds would have caught this in 8 minutes, not 2 hours.** The
synthesis reports were already suspicious-looking in size terms (they were not
suspicious at all, which should itself have been the clue), and a single
`place_design` run - about 8 minutes - would have shown the deterioration long
before a full route was attempted.

## Process notes from the same session

**Vivado's stdout is block-buffered when redirected to a file.** Watching the log
file's modification time and concluding "the process is dead" was wrong three times
in a row. The file can sit unchanged for many minutes while the router works. Judge
liveness by log *content* growth over a long window, or by the presence of the
process, not by mtime over five minutes.

**Long builds die across machine sleep.** Several attempts lost their Vivado
process mid-route after a long gap with no user activity. `powercfg /change
standby-timeout-ac 0` helps but did not fully prevent it here. Suspect the
environment before suspecting the tool when a process disappears with no error in
the log.

**PowerShell here-string replaces kept failing silently on CRLF files.** Repeated
attempts to patch Verilog with `-replace` and `Replace()` reported zero matches and
did nothing, wasting several cycles. The `edit` tool with a literal old/new string
worked every time. Use it for source edits; reserve regex replacement for
mechanical whole-word renames, and verify the result immediately afterwards.
