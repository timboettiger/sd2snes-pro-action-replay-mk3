`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_nmi_hook.v
//
// Redirects the SNES NMI vector to the MK3 PAR-NMI handler. Replaces the bytes
// at $00:FFEA (LSB) and $00:FFEB (MSB) with slot5[7:0] / slot6[7:0].
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_nmi_hook.sv.
//
// The actual MK3 NMI handler code lives in MK3 SRAM at $7E:7033 ff. — only the
// vector read itself is intercepted. Emulation-mode vector ($00:FFFA) is not
// hooked because the MK3 always switches to native mode before enabling NMIs.
//
// Slots are armed when non-zero (BIOS clears them when no NMI tick is wanted),
// so we never substitute a $0000 vector and crash the CPU.
//
// This module also tracks whether the CPU is currently *inside* the PAR-NMI
// handler, via the `in_par_nmi` latch. The mapper uses it to open the BIOS
// window at $AE12-$B3F6 only while the handler runs, so the BIOS never
// shadows the game ROM during normal gameplay (see parmk3_mapper.v).
//
//   SET   on the NMI vector low-byte read ($00:FFEA) when the hook is armed:
//         that read is the unambiguous "NMI is dispatching to $AE12" signal.
//   CLEAR on the read of $00:6180, which in the entire handler ($AE12-$B3F6)
//         happens exactly once -- the final `jmp ($6180)` at $B09D that hands
//         control back to the game's own NMI handler. Verified against the
//         BIOS disassembly: $6180 is touched by nothing else in range, and
//         the handler never accesses direct-page $80 (DP base $6100 would
//         alias it to $6180), so this edge is unique and exact.
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_nmi_hook.sv
// (commit 06666fe).
//////////////////////////////////////////////////////////////////////////////////
module parmk3_nmi_hook(
  input  CLK,
  input  RST_N,
  input  enable,
  input  [23:0] SNES_ADDR,
  input  [31:0] slot5,
  input  [31:0] slot6,
  output hit,
  output [7:0] override_byte,
  output in_par_nmi       // 1 while the CPU is inside the PAR-NMI handler
);

wire slot5_armed = (slot5 != 32'h0);
wire slot6_armed = (slot6 != 32'h0);

wire is_nmi_lo = enable & slot5_armed & (SNES_ADDR == 24'h00FFEA);
wire is_nmi_hi = enable & slot6_armed & (SNES_ADDR == 24'h00FFEB);

assign hit = is_nmi_lo | is_nmi_hi;
assign override_byte = is_nmi_lo ? slot5[7:0] : slot6[7:0];

// PAR-NMI presence latch. SET wins over CLEAR (they target different
// addresses, so they never collide, but the priority is explicit anyway).
reg  in_par_nmi_r;
wire par_nmi_enter = is_nmi_lo;                       // $00:FFEA read, hook armed
wire par_nmi_leave = (SNES_ADDR == 24'h006180);       // final jmp ($6180) at $B09D

always @(posedge CLK or negedge RST_N) begin
  if (!RST_N)              in_par_nmi_r <= 1'b0;
  else if (par_nmi_enter)  in_par_nmi_r <= 1'b1;
  else if (par_nmi_leave)  in_par_nmi_r <= 1'b0;
  // Safety net: if the hook is disabled (left Cheats Active), drop the
  // latch so a stale value can't keep the window open.
  else if (!enable)        in_par_nmi_r <= 1'b0;
end

assign in_par_nmi = in_par_nmi_r;

endmodule
