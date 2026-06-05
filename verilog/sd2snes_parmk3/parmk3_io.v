`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_io.v
//
// Pro Action Replay MK3 IO register bank. Snoops the SNES bus for writes to
// the MK3-specific register addresses and exposes the latched state to the
// mapper / cheat-interception modules.
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_io.sv.
//
// Registers (write-only from CPU; reads return open-bus on real HW):
//   $100000-$10001B  Slots 0-6, 4 bytes each
//                      byte 0 = DTA (substitute value)
//                      bytes 1-3 = 24-bit hook address
//   $10001C  Control A
//                      bit 4   = enable game-ROM peek through LoROM mirror
//                      bits 6-7 = forced video region (01 NTSC, 10 PAL)
//   $10003C  Control B (sticky bit 0 = "game mode" latch)
//   $206000  Control C (BIOS execution vs game execution flag)
//   $008000  Control D (PAR-NMI ack — semantics unclear, mirror state)
//   $086000  LEDs (bits 0-1 = left/right cartridge LEDs)
//////////////////////////////////////////////////////////////////////////////////
module parmk3_io(
  input  CLK,
  input  RST_N,
  input  [23:0] SNES_ADDR,
  input  cpu_we,                  // 1 when CPU drives a write on this cycle
  input  [7:0]  cpu_din,
  output [7:0]  cpu_dout,
  output cpu_hit,

  output [31:0] slot0,
  output [31:0] slot1,
  output [31:0] slot2,
  output [31:0] slot3,
  output [31:0] slot4,
  output [31:0] slot5,
  output [31:0] slot6,

  output [7:0]  control_a,
  output        control_b,
  output [7:0]  control_c,
  output [7:0]  control_d,
  output [7:0]  leds,
  output        control_b_just_set
);

reg [31:0] slot_r [0:6];
reg [7:0]  ca_r, cc_r, cd_r;
reg        cb_r;
reg        cb_pulse;
reg [7:0]  grp_r;          // mirror of $00:61FE (PAR-NMI live LED output)

wire is_slot = (SNES_ADDR >= 24'h100000) & (SNES_ADDR <= 24'h10001B);
wire is_ca   = (SNES_ADDR == 24'h10001C);
wire is_cb   = (SNES_ADDR == 24'h10003C);
wire is_cc   = (SNES_ADDR == 24'h206000);
wire is_cd   = (SNES_ADDR == 24'h008000);
// The PAR-NMI handler keeps the live LED output in MK3 SRAM at its DP
// $6100 + $FE = $00:61FE -- NOT at the $086000 hardware register, whose bit0
// the handler masks away (`and #$FE`) on every runtime write, leaving it stuck
// at the last boot pattern. $61FE carries the real blink for both LEDs:
//   bit0 = LED 1 (group): fast = A, slow = B, solid = both, 0 = none
//   bit1 = LED 2 (trainer): slow = many candidates, fast = one found
// Snoop it so the FPGA mirrors the authentic blink onto both status LEDs.
wire is_grp  = (SNES_ADDR == 24'h0061FE);

wire [2:0] slot_index = SNES_ADDR[4:2];
wire [1:0] slot_byte  = SNES_ADDR[1:0];

assign cpu_hit  = is_slot | is_ca | is_cb | is_cc | is_cd;
assign cpu_dout = 8'h00;

always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    slot_r[0] <= 32'h0;
    slot_r[1] <= 32'h0;
    slot_r[2] <= 32'h0;
    slot_r[3] <= 32'h0;
    slot_r[4] <= 32'h0;
    slot_r[5] <= 32'h0;
    slot_r[6] <= 32'h0;
    ca_r     <= 8'h0;
    cb_r     <= 1'b0;
    cc_r     <= 8'h0;
    cd_r     <= 8'h0;
    grp_r    <= 8'h0;
    cb_pulse <= 1'b0;
  end else begin
    cb_pulse <= 1'b0;
    // Group-LED status snoop -- separate from the IO-register decode below so it
    // never claims cpu_hit (the write still lands in MK3 SRAM normally).
    if (cpu_we & is_grp) grp_r <= cpu_din;
    if (cpu_we) begin
      if (is_slot) begin
        case (slot_byte)
          2'd0: slot_r[slot_index][7:0]   <= cpu_din;
          2'd1: slot_r[slot_index][15:8]  <= cpu_din;
          2'd2: slot_r[slot_index][23:16] <= cpu_din;
          2'd3: slot_r[slot_index][31:24] <= cpu_din;
        endcase
      end
      else if (is_ca)  ca_r   <= cpu_din;
      else if (is_cb) begin
        if (cpu_din[0] & ~cb_r) begin
          cb_r     <= 1'b1;
          cb_pulse <= 1'b1;
        end
        // sticky: cannot be cleared by CPU write
      end
      else if (is_cc)  cc_r   <= cpu_din;
      else if (is_cd)  cd_r   <= cpu_din;
    end
  end
end

assign slot0   = slot_r[0];
assign slot1   = slot_r[1];
assign slot2   = slot_r[2];
assign slot3   = slot_r[3];
assign slot4   = slot_r[4];
assign slot5   = slot_r[5];
assign slot6   = slot_r[6];
assign control_a          = ca_r;
assign control_b          = cb_r;
assign control_c          = cc_r;
assign control_d          = cd_r;
// LED status exposed to the mirror -- both bits from the live $61FE blink:
//   bit0 (group LED)   = $61FE bit0 (fast=A, slow=B, solid=both, 0=none)
//   bit1 (trainer LED) = $61FE bit1 (slow=many candidates, fast=one found)
assign leds               = {6'b0, grp_r[1], grp_r[0]};
assign control_b_just_set = cb_pulse;

endmodule
