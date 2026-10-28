# Switching the Ethernet receive path to the vendor MAC

Status: **ground work done and compiling, `eth_top` rewrite not started.**

The hand-written stack (`eth_udp_stack.v`, `eth_gmii_rx.v`, `eth_gmii_tx.v`) is being
replaced by the vendor's MAC from `ethernet_test.zip`. The reason is not that the
vendor code is better written - it is that it is known to work on this board, and
after several rounds of fixing one defect at a time in a hand-written stack, using
the proven design removes a whole class of unknowns.

---

## 1. What is already in the tree

```
rtl/eth/mac/                      20 files, compiles clean
    mac_top.v                     top of the vendor MAC
    mac_rx_top.v  mac_rx.v  mac_rx1.v
    mac_tx_top.v  mac_tx.v  mac_tx_mode.v
    ip_rx.v  ip_tx.v  ip_tx_mode.v
    udp_rx.v  udp_tx.v  arp_rx.v  arp_tx.v
    icmp_reply.v  arp_cache.v  crc.v  dpram.v
    vendor_ip.v                   the four Xilinx cores, rewritten in plain RTL
```

### The four cores that had to be replaced

The vendor RTL instantiates generated Xilinx cores that do not exist in this
project. Each is reproduced in `vendor_ip.v` with the same module name and port
names, so the vendor RTL is used unmodified:

| core | used by | shape |
|---|---|---|
| `udp_rx_ram_8_2048` | `udp_rx.v` | dual-port RAM, 2048x8, registered read on port B |
| `icmp_rx_ram_8_256` | `icmp_reply.v` | dual-port RAM, 256x8, registered read on port B |
| `udp_tx_data_fifo` | `udp_tx.v` | sync FIFO, 8 bit, `full`/`almost_full`/`empty`/`data_count[11:0]` |
| `udp_checksum_fifo` | `udp_tx.v` | sync FIFO, 32 bit, `full`/`empty`/`data_count[3:0]` |

**The one assumption to re-check first if transmission misbehaves**: the FIFOs are
implemented as registered-output, not first-word-fall-through. A FWFT FIFO would
present data one cycle earlier. If the vendor's transmitter shows a one-byte
offset, this is the place to look.

### A dead file was removed

`dhcp_tx.v` has a syntax error (a trailing comma before the closing parenthesis of
its port list) and is not instantiated by anything in the demo. Deleted rather than
repaired.

---

## 2. The `mac_top` interface contract

```verilog
mac_top (
    // ---- clocks ----
    .gmii_tx_clk, .gmii_rx_clk, .rst_n,

    // ---- identity ----
    .source_mac_addr  (48'h02_00_00_00_00_01),
    .TTL              (8'd64),
    .source_ip_addr   (32'hC0A80806),     // 192.168.8.6
    .destination_ip_addr,                 // learned or broadcast

    // ---- transmit: fill their RAM, then ask them to send ----
    .ram_wr_data, .ram_wr_en, .udp_ram_data_req,
    .udp_send_data_length, .udp_tx_req, .udp_tx_end, .almost_full,

    // ---- receive: they store the payload, you read it back ----
    .udp_rec_ram_rdata, .udp_rec_ram_read_addr,
    .udp_rec_data_length, .udp_rec_data_valid,

    // ---- ARP ----
    .arp_request_req, .arp_found, .mac_not_exist,

    // ---- GMII ----
    .rx_dv, .mac_rx_datain, .mac_tx_data, .mac_data_valid, .mac_send_end
);
```

### Transmit sequence (from `mac_test.v`)

```
1. wait for udp_ram_data_req          // "the RAM is free, start filling"
2. write N bytes with ram_wr_en/ram_wr_data
   N = udp_send_data_length
3. pulse udp_tx_req
4. wait for udp_tx_end
```

### Receive sequence

```
udp_rec_data_valid pulses when a datagram is complete
udp_rec_data_length holds how many bytes
then read bytes back with udp_rec_ram_read_addr (registered read, one cycle)
```

---

## 3. What the rewrite has to do

| # | task | notes |
|---|---|---|
| 1 | new `eth_top` instantiating `util_gmii_to_rgmii` + `mac_top` | replaces `eth_udp_stack`, `eth_gmii_rx`, `eth_gmii_tx` |
| 2 | reply path: loader bytes -> `ram_wr_en` -> `udp_tx_req` -> `udp_tx_end` | needs a length, and the loader does not drive `tlast`, so accumulate until idle like the old design did |
| 3 | command path: `udp_rec_data_valid` -> read RAM -> loader `ld_tdata` | |
| 4 | clock crossing | MAC runs at `gmii_rx_clk` (125 MHz), loader at 200 MHz; the two `eth_async_fifo` instances already exist |
| 5 | **debug counters** | see below |
| 6 | set `source_ip_addr = 32'hC0A80806` | 192.168.8.6, as requested |

---

## 4. The debug mechanism

The immediate question is "did anything arrive at all", so the counters must
separate three states that currently look identical:

| counter | counts | meaning if zero |
|---|---|---|
| `rx_dv` rising edges | every frame the PHY hands over, before any parsing | **nothing at all reaches the MAC** - a physical or clocking problem |
| `udp_rec_data_valid` pulses | datagrams that got through IP and UDP intact | frames arrive but are rejected before UDP |
| `arp_found` | ARP replies accepted | ARP is being parsed but the reply is not getting out |

Exposed as outputs of `eth_top` and shown as:

```
led[3] : solid  when rx_dv_count != 0        (any frame ever seen)
         blink  when rx_dv_count == 0        (nothing has ever arrived)
```

and, preferably, readable over JTAG so the count itself is visible rather than a
single bit. That needs extra bytes in the AXI bridge's STATUS response.

---

## 5. Honest scope

The four cores and the file extraction were the mechanical part and are done and
compiling. The `eth_top` rewrite is roughly 200 lines with three handshakes to get
right and a clock boundary to respect, and it has not been written yet.

Writing it and then declaring it working without simulating it would repeat the
pattern that has already cost several build cycles in this project. The next
session should write it, extend `tb_eth` to drive `mac_top` directly, and only
then build.
