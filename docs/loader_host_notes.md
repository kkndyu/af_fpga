# Driving the loader from a host: two rules that cost real time

Both of these produced value-correct-looking results that were wrong, because the
host, not the FPGA, was at fault.

## WRITE_A takes a start address, and each frame covers 32 values

```
0x02 WRITE_A  payload = [addr_hi][addr_lo] + 2*N data bytes
```

The address is where the *first* value of that frame lands. A frame carrying 64
data bytes writes 32 consecutive 16-bit values starting there.

Writing frame `k` to address `k` therefore overlaps the previous frame by 31
values, and each new frame overwrites the earlier ones with zeros. The result is
one or two surviving non-zero activations out of a thousand, and a GEMV output
of 2 where 64 was expected - with no error anywhere.

Correct stride:

```powershell
$base = $k * 32          # not $k
```

`WRITE_W` is not like this: its address selects one 256-bit row and one frame
writes exactly that row, so frame `k` to address `k` is right there.

## Blasting UDP is not free

Sending 4608 datagrams back to back from PowerShell delivered 9 of them. The
sends were failing and the script ignored the exception, so the symptom looked
like the FPGA dropping frames - which sent the investigation toward the receive
shim instead of the host.

`UdpClient.Send` throws when the socket buffer is full. Either check for the
exception, or pace the sends:

```powershell
try { [void]$u.Send($f, $f.Length, $board, $port) } catch { $fail++ }
Start-Sleep -Milliseconds 2
```

The FPGA-side counter that would have caught this immediately is `0x40`
(`rx_drop`, datagrams completing while the previous one is still being
forwarded). It reads zero in the healthy case; if the host sends faster than it
can, this is where it shows.

## Verifying a number, not just a path

The check that established the datapath is numerically correct:

```
weights:  rows 0..63, every lane code 2 (x1.0), i.e. every data byte 0x22
          (both nibbles are 2, so this does not depend on nibble order)
acts:     values 0..63 = 1, everything else 0
expect    lane j = sum over 64 rows of (1 x 1.0) = 64
measured  every lane 0..63 = 64
```

A value derived from first principles like this is the only thing that separates
"the path works" from "the arithmetic is right". Zero in, zero out proves
neither.
