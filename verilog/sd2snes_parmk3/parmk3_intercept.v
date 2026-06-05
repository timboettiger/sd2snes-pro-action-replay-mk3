`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_intercept.v
//
// Cheat-code bus interception. Replaces the cartridge data byte with a
// programmed substitute when the CPU fetches from a matching address.
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_intercept.sv.
//
// Slot format (32 bits): [31:8] = 24-bit hook address, [7:0] = DTA byte.
// Slots 5-6 are reserved for the NMI vector hook (parmk3_nmi_hook.v).
// A slot with addr == 0 is inactive.
//////////////////////////////////////////////////////////////////////////////////
module parmk3_intercept(
  input  CLK,
  input  enable,                   // 1 when effective_mode == CHEATS_ACTIVE
  input  [23:0] SNES_ADDR,
  input  [31:0] slot0,
  input  [31:0] slot1,
  input  [31:0] slot2,
  input  [31:0] slot3,
  input  [31:0] slot4,
  output hit,
  output [7:0] override_byte
);

wire [4:0] match;
assign match[0] = enable & (SNES_ADDR == slot0[31:8]) & (slot0 != 32'h0);
assign match[1] = enable & (SNES_ADDR == slot1[31:8]) & (slot1 != 32'h0);
assign match[2] = enable & (SNES_ADDR == slot2[31:8]) & (slot2 != 32'h0);
assign match[3] = enable & (SNES_ADDR == slot3[31:8]) & (slot3 != 32'h0);
assign match[4] = enable & (SNES_ADDR == slot4[31:8]) & (slot4 != 32'h0);

assign hit = |match;
assign override_byte = match[0] ? slot0[7:0]
                     : match[1] ? slot1[7:0]
                     : match[2] ? slot2[7:0]
                     : match[3] ? slot3[7:0]
                     : match[4] ? slot4[7:0]
                     :            8'h00;

endmodule
