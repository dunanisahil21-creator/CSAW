# CSAW 2026 AI Hardware Attack Challenge — Qualifier Submission

**Target:** Hackster iCE40-UP5K lightweight cryptographic accelerator ("LES"), SPI peripheral.
**Deliverable:** AI-recovered RTL + AI-generated key-exfiltration Trojan + exploit + full logs.
**Headline results:**
- Recovered the design from `ice40_bitstream.bin` and reproduced the official test vector
  (`encrypt(0x59C359C3)=0x9CD84392`, `decrypt(0x9CD84392)=0x59C359C3`).
- **Bonus — recovered the embedded key: `K = 0x8E043CB1`.**
- Inserted a stealthy two-stage Trojan that leaks `K` over `MISO`; demonstrated in simulation.

```
make all        # runs normal-operation + exploit testbenches (one command)
./run.sh        # same, with section headers
make recover    # re-derive the netlist from the bitstream
make keyrecover # re-run the known-plaintext key search (~minutes)
```

---

## 1. How the encryption system works

The accelerator is a **32-bit block cipher** with a **4-round substitution–permutation**
structure, sharing a single `SCK` clock domain and talking to the RP2040 over SPI with
discrete sideband control (`START`, `ENC_DEC`, `BUSY`, `NORM_CS_N`). We recovered the
round function and confirmed it against the provided test vector:

- **Encrypt** (`ENC_DEC=0`): `x_{i+1} = ROTL8( S( x_i ⊕ K ) )`, `x_0 = plaintext`, `ciphertext = x_4`
- **Decrypt** (`ENC_DEC=1`): `y_{i+1} = S⁻¹( ROTR8( y_i ) ) ⊕ K`, `y_0 = ciphertext`, `plaintext = y_4`

where `S` is the **AES S-box** (applied per byte), `ROTL8/ROTR8` are 8-bit (one-byte)
rotations, and `K` is a fixed 32-bit key **embedded in the FPGA fabric**. The two cores are
exact inverses and share the same `K`.

**Data flow (per the recovered design and block diagrams):** a 32-bit `MOSI` word is
shifted MSB-first into the SPI shift register while `NORM_CS_N` is low; `START` latches it
into the crypto core; the 2-bit round controller (`IDLE→R1→R2→R3→IDLE`) runs the four
rounds while `BUSY` is high; on the falling edge of `BUSY` the result is parallel-loaded back
into the shift register and clocked out over `MISO`. `ICE_LED` mirrors `BUSY`.

Clean reconstructed RTL: [`rtl/spi_les.v`](rtl/spi_les.v).

## 2. Reverse-engineering methodology

1. **Bitstream → netlist.** `iceunpack ice40_bitstream.bin design.asc` then
   `icebox_vlog design.asc > recovered_netlist.v` (Project IceStorm). Result:
   a 14.6k-line gate/LUT netlist ([`recovery/recovered_netlist.v`](recovery/recovered_netlist.v))
   with 71 flip-flops and **4 `SB_RAM40_4K` block RAMs**.
2. **Pin identification.** The nine `io_*` ports map to the documented interface by evidence,
   not guesswork: the port feeding every FF/RAM clock (`RCLK`) is `SCK` (`io_9_31_1`); the two
   outputs that are wired equal (`assign io_19_31_0 = io_8_31_1`) are `BUSY` and its mirror
   `ICE_LED`; the remaining output is `MISO`.
3. **Structure.** The four `SB_RAM40_4K` instances hold the S-box lookup tables (the cipher's
   only ROM), and the 32-bit datapath + 2-bit controller match the block diagrams. The key is
   *not* in RAM — it is baked into the XOR constants of the datapath, so we recover it
   analytically (§5).
4. **Clean re-expression + validation.** We rebuilt readable RTL from the recovered structure
   and diagrams, then **validated it against the ground-truth test vector** over the full SPI
   protocol (`tb/tb_normal.v`): SPI loopback, encryption, and decryption all pass. This closes
   the loop between the recovered bitstream and our editable design.

## 3. AI methodology (how the Trojan and exploit were generated)

- **Model / interaction.** The entire flow was driven by **Claude (Anthropic)** running in an
  **agentic Claude Code environment** — not copy-paste from a chat box. Claude had direct tool
  access to a shell, `iverilog`/`vvp`, and a C compiler, and operated in a
  **generate → simulate → inspect → repair loop**.
- **Agentic / automated steps.** (1) Claude unpacked and inspected the netlist and block
  diagrams; (2) it wrote and compiled a **C known-plaintext key-search** and ran it to recover
  `K` (§5); (3) it *programmatically generated* the RTL — the S-box tables are emitted into the
  Verilog by a script rather than hand-typed, eliminating transcription error; (4) it wrote the
  Trojan and both testbenches and **verified them in simulation in the loop**, iterating until
  all checks passed.
- **No human-written hardware.** All Verilog (clean RTL, Trojan, testbenches) was produced by
  the model. The complete interaction record is in [`ai/`](ai/).

## 4. The Trojan

File: [`rtl/spi_les_trojan.v`](rtl/spi_les_trojan.v).

- **Trigger — two-stage sequential (`~1/2⁶⁴`).** The Trojan arms when the plaintext
  `TRIG_A = 0xC0DEC0DE` is encrypted, and **fires only if the very next encryption** is
  `TRIG_B = 0xFEEDFACE`. Any other intervening operation disarms it. This is far more specific
  than a single magic constant, so accidental activation is effectively impossible.
- **Payload — precise key exfiltration.** On firing, the parallel-load step latches the
  embedded key `K` into the SPI shift register *instead of* the ciphertext, so the attacker
  reads the full 32-bit key straight out over `MISO` on the next readout. No key bits are ever
  guessed or brute-forced at exploit time — the hardware hands them over.
- **Stealth.** Identical latency and bus behaviour for every non-trigger input; even the arming
  operation returns the correct ciphertext of `TRIG_A`, so nothing looks wrong. Hardware
  overhead is a 32-bit comparator chain plus two flip-flops (`armed`, `pend_leak`); the crypto
  datapath is untouched.

## 5. Bonus — recovering the embedded key

Because the four-round key is constant, one known (plaintext, ciphertext) pair from the
provided test script is enough. `tools/keyrecover.c` sweeps all 2³² keys across the plausible
round structures (rotate direction × S-box × operation order) and finds those reproducing
`0x59C359C3 → 0x9CD84392` in four rounds.

A subtlety worth noting: byte-rotation **commutes** with the per-byte S-box, so a single pair
admits two algebraically-consistent readings — `ROTL8(S(x⊕K))` with `K=0x8E043CB1`, and
`ROTL8(S⁻¹(x⊕K))` with `K=0x5FB31A52`. We select the **forward-S-box form**, which matches the
S-boxes drawn in the block diagrams and the forward S-box tables present in the recovered
`SB_RAM40_4K` blocks:

> **Embedded key `K = 0x8E043CB1`.**

## 6. Exploiting it in hardware

Once a bitstream is regenerated from `rtl/spi_les_trojan.v`, the key is extracted over SPI with
three ordinary operations — no side channels, no special equipment:

1. **Arm:** send `0xC0DEC0DE` as plaintext, pulse `START` with `ENC_DEC=0`, read back the
   (normal-looking) ciphertext.
2. **Fire:** immediately send `0xFEEDFACE` as plaintext, pulse `START` with `ENC_DEC=0`.
3. **Read the key:** perform a normal 32-bit readout — `MISO` returns `0x8E043CB1`, the key.

`tb/tb_exploit.v` performs exactly this and also shows (a) an ordinary encryption still works and
(b) `TRIG_B` on its own does **not** leak. A waveform (`tb_exploit.vcd`) is produced for inspection.

```
[stealth ] encrypt 59C359C3 -> 9cd84392 : PASS
[control ] encrypt TRIG_B alone -> a6775216 : PASS (no leak)
[arm     ] encrypt TRIG_A -> 0bfb74b6 (normal-looking ciphertext)
[exploit ] encrypt TRIG_B -> 8e043cb1  : KEY LEAKED
```

## 7. Stealth evaluation vs. a GNN Trojan detector (extra)

Beyond the required deliverables, we evaluated the Trojan against the **TrojanGYM** GNN
Trojan-detector (`hw2vec`, 4-model ensemble). Both the clean and trojaned designs were scored:

| Design | Verdict | Trojan votes | mean P(trojan) |
|---|---|---|---|
| Clean LES | CLEAN | 0 / 4 | 0.169 |
| **Trojaned LES** | **CLEAN** | **0 / 4** | 0.245 |

The Trojan **evades all four detectors** — every model stays below the 0.5 decision threshold —
because the payload is a tiny comparator + two flags + one mux and leaves almost no data-flow-graph
signature. This is independent evidence for the stealth claim. See
[`evaluation/trojangym_detection.txt`](evaluation/trojangym_detection.txt).

## 8. Repository layout

```
README.md                     this technical brief
run.sh / Makefile             one-command build + simulate pipeline
rtl/spi_les.v                 clean recovered cipher (no Trojan)
rtl/spi_les_trojan.v          AI-generated key-leak Trojan
tb/tb_normal.v                proves normal operation (vector match)
tb/tb_exploit.v               proves stealth + demonstrates the key leak
recovery/recovered_netlist.v  raw icebox_vlog output from the bitstream
recovery/ice40_bitstream.bin  provided bitstream (for `make recover`)
tools/keyrecover.c            2^32 known-plaintext key search
evaluation/                   TrojanGYM GNN detector stealth check
ai/                           full AI interaction logs + chat transcript
docs/                         block diagrams
```

*For authorized hardware-security education and research (CSAW AHA Challenge).*
