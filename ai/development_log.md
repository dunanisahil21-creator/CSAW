# Development Log — AI-Assisted Generation

Chronological record of the AI-driven workflow. Each phase lists the human request (prompt
intent), what the model (Claude, agentic Claude Code) did, and the output. Hardware was produced
entirely by the model via tool-assisted iteration.

---

## Phase 0 — Ingest the challenge
**Prompt:** "Here is the qualifier package (bitstream, IP doc, SPI test script, block diagrams).
Reverse-engineer it and build the best possible submission."
**AI actions:** Read `ice40_cryptographic_IP.md` (SPI interface, ports, timing), the micropython
test (`spi_ice40_crypto_ip_test.py` → known pair `0x59C359C3 → 0x9CD84392`), and the four block
diagrams (top-level, encryption core, decryption core, round controller).
**Output:** A plan — recover netlist → identify structure → recover key → reconstruct clean RTL →
insert Trojan → build exploit TB → validate everything in simulation.

## Phase 1 — Bitstream reverse engineering
**AI actions (shell):**
```
iceunpack ice40_bitstream.bin design.asc          # 14,588-line ASCII bitstream
icebox_vlog design.asc > recovered_netlist.v       # 45,718-line gate netlist
```
Inspected the netlist: `module chip` with 9 I/O, 71 flip-flops, **4 `SB_RAM40_4K`** block RAMs.
Identified pins by evidence: clock = `io_9_31_1` (drives `RCLK`/all FFs); `assign io_19_31_0 =
io_8_31_1` reveals `ICE_LED` mirroring `BUSY`; remaining output = `MISO`. Located the S-box in the
RAM `INIT_*` parameters.
**Output:** Confirmed the documented architecture; established that the key is embedded in datapath
XOR constants (not in RAM), so it must be recovered analytically.

## Phase 2 — Key recovery (known-plaintext)
**AI reasoning:** The 4-round key is constant, so one known pair suffices. Wrote a C brute-forcer
sweeping all 2³² keys across candidate round structures (rotate dir × S-box × op order).
**AI actions:** authored `keyrecover.c`, compiled `-O3`, ran it (≈5 min for the full sweep).
**Output (verbatim):**
```
HIT rot=ROTL tbl=S  order=2  K=0x8E043CB1
HIT rot=ROTL tbl=IS order=2  K=0x5FB31A52
```
The model noted that byte-rotation commutes with the per-byte S-box, which is why two readings
appear, and selected the **forward-S form, `K=0x8E043CB1`**, consistent with the diagrams' S-boxes
and the forward S-box tables in the recovered RAM.

## Phase 3 — Clean RTL reconstruction
**AI actions:** Wrote a generator that bakes the AES S-box / inverse S-box into flat Verilog
constants, then emitted [`rtl/spi_les.v`](../rtl/spi_les.v): a 32-bit, 4-round cipher with the
recovered round functions, a 2-bit round controller (`IDLE→R1→R2→R3`), and the SPI shift register
with the documented `clr > load > shift` priority and `BUSY` falling-edge parallel load.
**Verification (in the loop):** authored `tb/tb_normal.v` to drive the full SPI protocol and
compiled/ran it:
```
SPI loopback : wrote 59c359c3 read 59c359c3 -> PASS
ENCRYPT      : 59c359c3 -> 9cd84392 (expect 9cd84392) -> PASS
DECRYPT      : 9cd84392 -> 59c359c3 (expect 59c359c3) -> PASS
```
**Output:** A validated, editable reconstruction matching the ground-truth hardware behavior.

## Phase 4 — Trojan design and insertion
**Prompt intent:** "Insert a stealthy, high-severity AI-generated Trojan; prefer precise key
exfiltration."
**AI design:** a **two-stage sequential trigger** (encrypt `0xC0DEC0DE` to arm, then encrypt
`0xFEEDFACE` to fire; any other op disarms → `~1/2⁶⁴`) with a **key-leak payload** (parallel-load
latches `K` into the shift register instead of ciphertext). Chosen for Exemplary stealth/severity:
identical timing and bus behavior otherwise, ~0 datapath overhead.
**AI actions:** emitted [`rtl/spi_les_trojan.v`](../rtl/spi_les_trojan.v) (clean core + trigger FSM
+ payload mux).

## Phase 5 — Exploit demonstration (in the loop)
**AI actions:** authored `tb/tb_exploit.v` (stealth check + negative control + arm/fire sequence,
with VCD dump), compiled and ran; iterated until green:
```
[stealth ] encrypt 59C359C3 -> 9cd84392 : PASS
[control ] encrypt TRIG_B alone -> a6775216 : PASS (no leak)
[arm     ] encrypt TRIG_A -> 0bfb74b6 (normal-looking ciphertext)
[exploit ] encrypt TRIG_B -> 8e043cb1  : KEY LEAKED
RESULT: ALL CHECKS PASSED
```

## Phase 6 — Automation and packaging
**AI actions:** wrote `Makefile` + `run.sh` for a one-command recover→simulate→report pipeline,
the technical brief (`README.md`), and these logs; packaged the submission in the required
`README / rtl/ / tb/ / ai/` layout.

---

### Notes on reproducibility
- `make keyrecover` re-runs the exact 2³² search that produced `K`.
- `make recover` re-derives the netlist from the included bitstream.
- `make all` re-runs both testbenches; both are deterministic and self-checking.
