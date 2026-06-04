`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_mapper.v
//
// Pro Action Replay MK3 wrapper mapper. Decides whether a CPU bus access
// targets the MK3 BIOS, the wrapped game cart, or the 32 KB MK3 SRAM.
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_mapper.sv,
// converted from SystemVerilog to Verilog-2001 and adapted to the sd2snes
// signal naming conventions.
//
// Memory map (LoROM-style host game):
//   $00/02/04/06 : $6000-$7FFF -> MK3 SRAM (paged, 32 KB total)
//   $00-$3F      : $8000-$FFFF -> BIOS in menu mode, game ROM otherwise
//   $80-$BF      : $8000-$FFFF -> always BIOS in menu mode (BIOS exec range)
//////////////////////////////////////////////////////////////////////////////////
module parmk3_mapper(
  input  CLK,
  input  [1:0]  switch_pos,        // 0=NoCheats 1=CheatsActive 2=MK3Menu
  input  control_b,                // sticky game-launch latch from parmk3_io
  input  [7:0] control_a,          // bit 4 = peek game ROM through LoROM mirror
  input  [23:0] SNES_ADDR,
  output sel_mk3_bios,
  output sel_game_rom,
  output sel_mk3_sram,
  output [14:0] sram_offset,
  output [16:0] bios_offset,
  output [1:0]  effective_mode    // 0=MK3_MENU 1=CHEATS_ACTIVE 2=NO_CHEATS
);

reg [1:0] mode;
always @* begin
  if (control_b) begin
    // Game running — Control B wins over the switch position.
    mode = (switch_pos == 2'd0) ? 2'd2 : 2'd1;
  end else begin
    // Idle / in-menu — every switch position resolves to the menu until
    // the BIOS latches Control B as part of its launch trampoline.
    mode = 2'd0;
  end
end
assign effective_mode = mode;

// SRAM decode: banks $00/$02/$04/$06, $6000-$7FFF.
wire bank_eligible = (SNES_ADDR[23:19] == 5'b00000) & (SNES_ADDR[16] == 1'b0);
wire sram_window   = (SNES_ADDR[15:13] == 3'b011);
assign sel_mk3_sram = bank_eligible & sram_window;

// 32 KB chip is *paged* across the four bank mirrors — see the upstream
// openFPGA comment for the hang-8266-A4E1 motivation behind this offset.
assign sram_offset = {SNES_ADDR[18:17], SNES_ADDR[12:0]};

wire rom_region        = SNES_ADDR[15];
wire is_fastrom_range  = (SNES_ADDR[23:22] == 2'b10);  // $80-$BF
wire is_lorom_mirror   = (SNES_ADDR[23:22] == 2'b00);  // $00-$3F

reg is_mk3_bios_path;
reg is_game_path;
always @* begin
  if (mode == 2'd0) begin
    is_mk3_bios_path = is_fastrom_range | (is_lorom_mirror & ~control_a[4]);
    is_game_path     = is_lorom_mirror & control_a[4];
  end else begin
    is_mk3_bios_path = 1'b0;
    is_game_path     = is_fastrom_range | is_lorom_mirror;
  end
end
assign sel_mk3_bios = rom_region & is_mk3_bios_path;
assign sel_game_rom = rom_region & is_game_path;

// BIOS offset: LoROM-style, 4 banks * 32 KB = 128 KB
assign bios_offset = {SNES_ADDR[17:16], SNES_ADDR[14:0]};

endmodule
