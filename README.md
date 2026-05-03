# RV64I 5-Stage Pipelined CPU

> A fully functional 64-bit RISC-V CPU core written in SystemVerilog, featuring a classic 5-stage pipeline with full hazard detection, data forwarding, and branch/jump resolution. Verified in simulation and deployed on a Xilinx Arty A7-100T FPGA.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Pipeline Stages](#pipeline-stages)
- [Hazard Handling](#hazard-handling)
- [Instruction Support](#instruction-support)
- [Module Reference](#module-reference)
- [Memory Map](#memory-map)
- [IO / Peripheral Interface](#io--peripheral-interface)
- [FPGA Deployment](#fpga-deployment)
- [Simulation & Tests](#simulation--tests)
- [Known Limitations](#known-limitations)
- [File Structure](#file-structure)

---

## Overview

This project implements a **RV64I** (64-bit RISC-V Integer) CPU using a classic **5-stage in-order pipeline**:

```
IF → ID → EX → MEM → WB
```

Key features:

- Full RV64I base integer instruction set
- RV64M word-width extension instructions (ADDW, SUBW, SLLW, SRLW, SRAW, ADDIW, SLLIW, SRLIW, SRAIW)
- 3-operand data forwarding (EX→MEM, MEM→WB)
- Load-use hazard detection and stall insertion
- Branch and jump resolution with pipeline flush
- Post-flush shadow-fetch suppression (prevents invalid instructions from leaking after a control transfer)
- Memory-mapped IO with 7-segment display peripheral
- Synthesized and tested on **Xilinx Arty A7-100T** FPGA

---

## Architecture

```
         ┌─────────────────────────────────────────────────────────────┐
         │                      rv64_core                              │
         │                                                             │
  clk ──►│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐           │
  rst ──►│  │  IF  │─►│  ID  │─►│  EX  │─►│ MEM  │─►│  WB  │           │──► seg[6:0]
         │  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘           │
         │      │         │         │          │          │            │
         │    IF/ID     ID/EX     EX/MEM    MEM/WB     wb_data         │
         │              │                               │              │
         │           regfile ◄───────────────────────── │              │
         │                                                             │
         │  ◄─────── forwardA / forwardB ──────────────►               │
         │  ◄─────── stall / flush ────────────────────►               │
         └─────────────────────────────────────────────────────────────┘
```

### Data path summary

| Signal | Direction | Description |
|--------|-----------|-------------|
| `pc` | internal | Current program counter |
| `pc_next` | internal | Next PC (pc+4, branch target, or jump target) |
| `flush` | internal | Asserted on taken branch or jump — clears IF/ID and ID/EX |
| `flush_d` | internal | flush delayed 1 cycle — suppresses shadow fetch after control transfer |
| `stall` | internal | Asserted on load-use hazard — freezes PC and IF/ID, inserts bubble |
| `forwardA/B` | internal | 2-bit forwarding select for ALU inputs A and B |
| `fwdA/fwdB` | internal | Forwarded operand values fed into EX stage |
| `wb_data` | internal | Final writeback value (ALU result, load data, or return address) |

---

## Pipeline Stages

### IF — Instruction Fetch

- PC is registered. On reset it goes to `0x0`.
- Instruction memory (`imem`) is a 1024-entry × 32-bit synchronous block RAM.
- Fetch is **combinational**: `instr_raw = imem[pc[11:2]]`.
- Invalid instructions (garbage, unrecognized opcodes, post-flush shadow) are replaced with `NOP (0x00000013)` before entering IF/ID.
- `flush_d` suppresses the fetch one cycle after a control transfer, preventing the shadow instruction at the old PC from propagating.

### ID — Instruction Decode

- The `decode` module extracts fields, generates the immediate, and produces all control signals.
- The register file is read here using `rs1` and `rs2` extracted from `if_id.instr`.
- Load-use stall is detected here: if the instruction in EX is a load whose destination matches `rs1` or `rs2` of the current instruction, `stall` is asserted.

### EX — Execute

- Forwarding muxes select between register file value, EX→MEM result, or MEM→WB result.
- The ALU computes the result using `fwdA`, `fwdB` (or immediate), and `alu_op`.
- Branch condition is evaluated here using the forwarded `a` and `b` values.
- Branch and jump targets are computed here: `pc + imm` for branches/JAL, `(a + imm) & ~1` for JALR.

### MEM — Memory Access

- Data memory (`dmem`) is a 1024-entry × 64-bit block RAM.
- Address range `0x0000–0x7FFF` is RAM; `0x0800–0x08FF` is memory-mapped IO.
- Load data is sign- or zero-extended based on `funct3` (LB/LH/LW/LD/LBU/LHU/LWU).
- Store merging is done combinationally into `w_next` before the sequential write.
- IO writes go to `digit_reg` which drives the 7-segment display.
- Load data (`mem_data_comb`) is passed directly to MEM/WB without an extra register cycle, eliminating a 1-cycle load latency bug.

### WB — Writeback

- Three-way mux selects the writeback value:
  - `jump = 1`: `wb_data = pc + 4` (return address for JAL/JALR)
  - `mem_to_reg = 1`: `wb_data = mem_data` (load result)
  - otherwise: `wb_data = alu_out`
- Writes to `rd` via `regfile` with `we = mem_wb.reg_write`.
- x0 is permanently hardwired to 0 — writes to rd=0 are silently ignored.

---

## Hazard Handling

### Data hazards — forwarding

The forwarding unit checks the pipeline registers each cycle and selects the most recent valid result:

| Condition | `forwardA/B` | Source |
|-----------|-------------|--------|
| `ex_mem.reg_write && !ex_mem.mem_read && ex_mem.rd == id_ex.rs1/rs2` | `2'b10` | EX→MEM ALU result |
| `mem_wb.reg_write && mem_wb.rd == id_ex.rs1/rs2` | `2'b01` | MEM→WB (wb_data) |
| otherwise | `2'b00` | Register file value |

EX→MEM forwarding has priority over MEM→WB. `rd = 0` is never forwarded.

### Load-use hazard — stall

When the instruction in EX is a load (`id_ex.mem_read = 1`) and its destination register matches `rs1` or `rs2` of the instruction currently in ID:

- PC is frozen (not incremented)
- IF/ID register is frozen (instruction replayed)
- ID/EX register is zeroed (NOP bubble inserted)
- The pipeline effectively stalls for one cycle

### Control hazards — flush

Branch resolution happens at the end of the EX stage (in the MEM pipeline register). When a branch is taken or a jump executes:

- `flush = 1` is asserted for one cycle
- IF/ID and ID/EX are both cleared to NOP
- PC is redirected to `ex_mem.target`
- `flush_d` asserts for the following cycle to suppress the shadow fetch at the redirected-from PC

This results in a **2-cycle branch penalty** (the two instructions fetched after the branch are squashed).

---

## Instruction Support

### RV64I Base Integer

| Category | Instructions |
|----------|-------------|
| Arithmetic | ADD, ADDI, SUB |
| Logical | AND, ANDI, OR, ORI, XOR, XORI |
| Shift | SLL, SLLI, SRL, SRLI, SRA, SRAI |
| Compare | SLT, SLTI, SLTU, SLTIU |
| Load | LB, LH, LW, LD, LBU, LHU, LWU |
| Store | SB, SH, SW, SD |
| Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| Jump | JAL, JALR |
| Upper imm | LUI, AUIPC |

### RV64M Word-width Extension

| Instructions |
|-------------|
| ADDW, ADDIW, SUBW |
| SLLW, SLLIW, SRLW, SRLIW, SRAW, SRAIW |

### Immediate encoding

| Format | Bits | Notes |
|--------|------|-------|
| I-type | `{52{instr[31]}, instr[31:20]}` | 12-bit signed |
| S-type | `{52{instr[31]}, instr[31:25], instr[11:7]}` | 12-bit signed |
| B-type | `{51{instr[31]}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}` | 13-bit signed, **51-bit** sign extension |
| U-type | `{instr[31:12], 12'b0}` | 32-bit, upper 20 bits |
| J-type | `{43{instr[31]}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}` | 21-bit signed |

> **Note:** B-type uses 51-bit sign extension (not 52) to correctly produce a 64-bit result. U-type is sign-extended from bit 31 for RV64I correctness.

---

## Module Reference

### `rv64_core`

Top-level CPU module. Instantiates all pipeline stages, hazard logic, memory, and IO.

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset |
| `seg` | output | 7 | 7-segment display segments |

### `decode`

Combinational decode of a 32-bit RISC-V instruction.

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `instr` | input | 32 | Raw instruction word |
| `rs1, rs2, rd` | output | 5 | Register specifiers |
| `funct3, funct7` | output | 3,7 | Function codes |
| `opcode` | output | 7 | Opcode field |
| `imm` | output | 64 | Sign-extended immediate |
| `reg_write` | output | 1 | Write enable for rd |
| `mem_read` | output | 1 | Load instruction |
| `mem_write` | output | 1 | Store instruction |
| `mem_to_reg` | output | 1 | Select load data for WB |
| `alu_src` | output | 1 | Use immediate as ALU op2 |
| `branch` | output | 1 | Branch instruction |
| `jump` | output | 1 | JAL or JALR |
| `alu_op` | output | 5 | ALU operation selector |

### `execute`

ALU, branch evaluator, and target address calculator.

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `a, b` | input | 64 | ALU operands (post-forwarding) |
| `imm` | input | 64 | Sign-extended immediate |
| `alu_src` | input | 1 | Select imm as op2 |
| `alu_op` | input | 4 | ALU operation |
| `branch, jump` | input | 1 | Control type flags |
| `funct3` | input | 3 | Branch condition selector |
| `opcode` | input | 7 | Used to distinguish JAL vs JALR |
| `pc` | input | 64 | Current instruction PC |
| `alu_out` | output | 64 | ALU result |
| `branch_taken` | output | 1 | Branch condition evaluated |
| `target` | output | 64 | Branch or jump target address |

### `regfile`

32 × 64-bit register file with synchronous write and asynchronous read.

- x0 is hardwired to 0 — reads always return 0, writes are ignored.
- Includes write-before-read bypass: if WB is writing to the same register being read, the new value is forwarded combinationally.

### `seven_seg`

Combinational 4-bit BCD to 7-segment decoder (common-anode active-low encoding).

### `top`

FPGA wrapper. Instantiates `rv64_core` with:
- Synchronised reset from button input
- Clock divider (100 MHz → ~2 Hz toggle = 1 Hz effective CPU clock for visual debugging)

---

## Memory Map

| Address range | Region | Notes |
|---------------|--------|-------|
| `0x0000 – 0x7FFF` | Data RAM | 1024 × 64-bit words |
| `0x0800` | IO: digit register | Write lower 4 bits → drives 7-seg display |
| `0x0808` | IO: timer | 32-bit free-running counter, read-only |

Instruction memory (`imem`) is separate: 1024 × 32-bit, loaded from `program.mem` at elaboration time via `$readmemh`.

---

## IO / Peripheral Interface

### 7-Segment Display

Write any 4-bit value to address `0x800` using a store instruction. The `seven_seg` module drives the `seg[6:0]` output directly from the stored digit.

```asm
li   t0, 0x800         # IO base address
li   t1, 5             # digit to display
sw   t1, 0(t0)         # write to digit register → displays "5"
```

Reading back from `0x800` returns the current digit value. Reading from `0x808` returns the 32-bit cycle timer.

---

## FPGA Deployment

**Target board:** Xilinx Arty A7-100T

### Constraints summary

| Signal | FPGA pin | Standard |
|--------|----------|----------|
| `clk` | E3 | LVCMOS33 |
| `rst_btn` | D9 | LVCMOS33 |
| `seg[0]` (A) | A18 | LVCMOS33 |
| `seg[1]` (B) | A11 | LVCMOS33 |
| `seg[2]` (C) | D12 | LVCMOS33 |
| `seg[3]` (D) | B18 | LVCMOS33 |
| `seg[4]` (E) | B11 | LVCMOS33 |
| `seg[5]` (F) | G13 | LVCMOS33 |
| `seg[6]` (G) | D13 | LVCMOS33 |

7-segment display connected via PMOD headers. Clock is divided from 100 MHz to ~1 Hz inside `top.sv` for visual debugging.

### FPGA test program

The following program was loaded and verified on hardware, cycling digit values on the 7-segment display:

```
00000093   addi  x1, x0, 0       # x1 = 0 (digit start)
000011b7   lui   x3, 0x1         # x3 = 0x1000 (base for IO, adjust as needed)
80018193   addi  x3, x3, -2048   # x3 = IO base 0x800
00000093   addi  x1, x0, 0
00208093   addi  x1, x1, 2       # increment
0011a023   sw    x1, 0(x3)       # write digit to display
00508093   addi  x1, x1, 5
0011a023   sw    x1, 0(x3)
ffd08093   addi  x1, x1, -3
0011a023   sw    x1, 0(x3)
fe1ff06f   jal   x0, -32         # loop back
```
**Result:**
<img width="3244" height="2720" alt="IMG_20260504_012458" src="https://github.com/user-attachments/assets/9b68348d-5ac2-4434-85c4-b8d2a1bad9d4" />
<img width="3192" height="2824" alt="IMG_20260504_012526" src="https://github.com/user-attachments/assets/32b9c7c2-3502-4237-bfc9-e224e71a7d0f" />
<img width="3096" height="2736" alt="IMG_20260504_012714" src="https://github.com/user-attachments/assets/bbdd8ad7-c7e7-4216-a185-c2874453f6a9" />
**Result: PASSED** — digits cycle correctly on the 7-segment display.

---

## Simulation & Tests

All tests were run using a SystemVerilog testbench (`rv64_tb`) that dumps per-cycle pipeline state.

### Test 1 — Core pipeline + hazards

Exercises: forwarding, load-use stall, branch taken/not-taken, invalid instruction rejection, JAL, JALR.

```
00000013   nop
00500093   addi  x1,  x0, 5       → x1 = 5
00a00113   addi  x2,  x0, 10      → x2 = 10
002081b3   add   x3,  x1, x2      → x3 = 15   [EX→MEM fwd on x1, x2]
00318233   add   x4,  x3, x3      → x4 = 30   [EX→MEM fwd on x3]
004202b3   add   x5,  x4, x4      → x5 = 60   [EX→MEM fwd on x4]
00503023   sd    x5,  0(x0)       → dmem[0] = 60
00003303   ld    x6,  0(x0)       → x6 = 60   [load-use stall: 1 cycle]
006303b3   add   x7,  x6, x6      → x7 = 120
00738433   add   x8,  x7, x6      → x8 = 180
00840663   beq   x8,  x8, +12     → branch taken → flush 2 instructions
00100493   addi  x9,  x0, 1       → SKIPPED (flushed)
00948463   beq   x9,  x9, +8      → SKIPPED (flushed)
deadbeef   <invalid>              → NOP injected
00200513   addi  x10, x0, 2       → NOP (post-flush gate)
008000ef   jal   x1,  +8          → x1 = return addr, jump to 0x44
badc0ffe   <invalid>              → SKIPPED (flushed by jal)
00300593   addi  x11, x0, 3       → x11 = 3
00058067   jalr  x0,  x11, 0      → jump to x11 = 0x0 (restart)
```

**Result: PASSED** ✓ All register values, forwarding paths, stall, flush, and invalid-instruction suppression verified cycle-by-cycle.

### Test 2 — Extended ALU, shifts, branches, subroutine call

A larger program exercising the full ALU, shift instructions, multiple branch conditions, subroutine call/return via JAL/JALR, and memory load/store patterns.

```
00100093   addi  x1,  x0, 1
00200113   addi  x2,  x0, 2
002081b3   add   x3,  x1, x2      → x3 = 3
00318233   add   x4,  x3, x3      → x4 = 6
003202b3   add   x5,  x4, x3      → x5 = 9
00503023   sd    x5,  0(x0)       → store 9
00403423   sd    x4,  8(x0)       → store 6
00003303   ld    x6,  0(x0)       → x6 = 9
00803383   ld    x7,  8(x0)       → x7 = 6
00730433   add   x8,  x6, x7      → x8 = 15
0ff00493   addi  x9,  x0, 255
00902823   sw    x9,  16(x0)
01002503   lw    x10, 16(x0)      → x10 = 255 (sign-extended)
01006583   lwu   x11, 16(x0)      → x11 = 255 (zero-extended)
00900c23   sh    x9,  24(x0)
01800603   lb    x12, 24(x0)      → x12 = -1 (sign-extended byte)
01804683   lbu   x13, 24(x0)      → x13 = 255 (zero-extended byte)
00a00713   addi  x14, x0, 10
01400793   addi  x15, x0, 20
00f72833   slt   x16, x14, x15    → x16 = 1 (10 < 20)
00e7a8b3   slt   x17, x15, x14   → x17 = 0 (20 < 10 false)
00f73933   sltu  x18, x14, x15   → x18 = 1
00100993   addi  x19, x0, 1
00799a13   slli  x20, x19, 7     → x20 = 128
003a5a93   srli  x21, x20, 3     → x21 = 16
403a5b13   srai  x22, x20, 3     → x22 = 16 (positive, same)
fff00b93   addi  x23, x0, -1
404bdc13   srai  x24, x23, 2     → x24 = -1 (arithmetic shift)
00001cb7   lui   x25, 1
00000d17   auipc x26, 0
01ac8db3   add   x27, x25, x26
00500e13   addi  x28, x0, 5
00500e93   addi  x29, x0, 5
01de1663   bne   x28, x29, skip  → NOT taken (equal)
06300093   addi  x1,  x0, 99     → executes
01de0463   beq   x28, x29, +8   → taken → skips next
00000093   addi  x1,  x0, 0      → SKIPPED
04d00113   addi  x2,  x0, 77
008000ef   jal   x1,  func       → call subroutine
00000063   beq   x0, x0, halt    → halt loop
02a00213   addi  x2, x0, 42      # func body
00008067   jalr  x0, x1, 0       # return
```

**Result: PASSED** ✓

---

## Known Limitations

| Item | Notes |
|------|-------|
| No M-extension multiply/divide | Only integer ALU ops implemented |
| No CSR / privilege levels | No exceptions, traps, or interrupt handling |
| No F/D floating-point | Integer only |
| imem limited to 4KB | `pc[63:12] == 0` bounds check; extend by widening the check |
| dmem limited to 8KB | `alu_out[63:13] == 0`; extend similarly |
| 2-cycle branch penalty | Branch resolved in MEM stage; could be moved to EX for 1-cycle penalty |
| No branch predictor | Always fetch sequentially, flush on taken |
| Single-issue in-order | No out-of-order or superscalar execution |

---

## File Structure

```
CoreSelva-RV64-P5/
├── program/                         # Instruction memory
│   └── program.mem                 # Hex program loaded via $readmemh

├── rtl/                            # CPU design (SystemVerilog)
│   ├── rv64_core.sv                # 5-stage pipeline core
│   ├── decode.sv                   # Instruction decode + immediate generation
│   ├── execute.sv                  # ALU + branch logic + target calculation
│   ├── regfile.sv                  # Register file
│   └── seven_seg.sv                # 7-segment display driver

├── sim/                            # Simulation
│   └── rv64_tb.sv                  # Testbench

├── Vivado Arty A7/                # Ready-to-use FPGA project
│   └── RV64-P5 Arty A7/
│       ├── RV64-P5 arty a7 100t.xpr      # Open this in Vivado
│       └── RV64-P5 arty a7 100t.srcs/    # Sources + constraints
```

---

## Results Summary

| Test | Platform | Result |
|------|----------|--------|
| Core pipeline, forwarding, hazards, JAL/JALR | ModelSim / VCS simulation | ✅ PASSED |
| Extended ALU, shifts, branches, subroutine call | Simulation | ✅ PASSED |
| FPGA boot + 7-segment digit display | Arty A7-100T @ 1 Hz | ✅ PASSED |

---

## License

This project is licensed under the MIT License.

You are free to use, modify, and distribute this project, including for commercial purposes, provided that the original copyright and license notice are included.

See the [LICENSE](LICENSE) file for full details.

*Built with SystemVerilog. Verified with simulation and FPGA hardware.*

---
