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
//////////////////////////////////////////////////////////////////////////////////
module parmk3_nmi_hook(
  input  CLK,
  input  enable,
  input  [23:0] SNES_ADDR,
  input  [31:0] slot5,
  input  [31:0] slot6,
  output hit,
  output [7:0] override_byte
);

wire slot5_armed = (slot5 != 32'h0);
wire slot6_armed = (slot6 != 32'h0);

wire is_nmi_lo = enable & slot5_armed & (SNES_ADDR == 24'h00FFEA);
wire is_nmi_hi = enable & slot6_armed & (SNES_ADDR == 24'h00FFEB);

assign hit = is_nmi_lo | is_nmi_hi;
assign override_byte = is_nmi_lo ? slot5[7:0] : slot6[7:0];

endmodule
