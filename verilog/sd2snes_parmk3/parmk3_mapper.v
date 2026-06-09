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
  input  RST_N,
  input  [1:0]  switch_pos,        // 0=NoCheats 1=CheatsActive 2=MK3Menu
  input  control_b,                // sticky game-launch latch from parmk3_io
  input  [7:0] control_a,          // bit 4 = peek game ROM through LoROM mirror
  input         in_par_nmi,        // from parmk3_nmi_hook: 1 while inside PAR-NMI handler
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

// PAR-NMI handler window: exact byte range $xx:AE12-$B3F6, in both the
// LoROM mirror ($00-$3F) and the FastROM image ($80-$BF). Slots 5/6 are
// programmed with #$AE12 at $80:912B, so the NMI vector hook redirects the
// SNES NMI to $80:AE12. The 1509-byte window covers:
//   $AE12-$AE42  NMI entry, register save, control writes, cheat dispatch
//   $AE99-$AECC  Combo decoder (Select+X/Y/A/B/R/Start/Up/Down/L)
//   $AFD0-$B083  Per-frame LED engine (drives $00:61FE bit0 + bit1)
//   $B083-$B09D  NMI exit (writes Control C=1 at $B08B, then stack pops
//                + jmp ($6180) back to the game's NMI handler)
//   $B0A0-$B3F6  Cheat-apply + trainer-count helpers (SRAM-trampoline
//                re-entries via jmp $80:B0A0 etc.)
//
// CRITICAL: the window is gated by in_par_nmi (from parmk3_nmi_hook), NOT
// left open for all of Cheats Active mode. The $AE12-$B3F6 range sits inside
// the LoROM $8000-$FFFF game window of every bank, so leaving it BIOS-mapped
// all the time would shadow 1509 bytes of game ROM in every bank and the
// game would crash on the first access there (verified: SMW freezes right
// after the Nintendo logo with an always-open window).
//
// in_par_nmi is set on the NMI vector fetch ($00:FFEA) and cleared on the
// handler's final jmp ($6180) -- the indirect-target read at $B09D, which
// the disassembly confirms is the only $00:6180 access in the entire
// handler (and DP $80 is never used, so $6100 + $80 = $6180 is not aliased
// by direct-page access). The latch spans the whole handler including the
// exit tail ($B08F-$B09D, after the ROM writes Control C = 1 at $B08B),
// so those exit fetches stay on BIOS.
//
// We deliberately do NOT gate on Control C: it would close at $B08B,
// before $B08F-$B09D finishes. control_c stays latched in parmk3_io for
// debug / future use but is unused here.
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_mapper.sv
// (commit 06666fe).
wire is_nmi_window = (SNES_ADDR[15:0] >= 16'hAE12)
                   & (SNES_ADDR[15:0] <= 16'hB3F6);

reg is_mk3_bios_path;
reg is_game_path;
always @* begin
  if (mode == 2'd0) begin
    is_mk3_bios_path = is_fastrom_range | (is_lorom_mirror & ~control_a[4]);
    is_game_path     = is_lorom_mirror & control_a[4];
  end else if (mode == 2'd1) begin
    // Cheats Active: game ROM everywhere, EXCEPT while the PAR-NMI handler
    // is running -- then the $AE12-$B3F6 window shows BIOS. Gating on
    // in_par_nmi (not just the address range) is essential: this range
    // overlaps the game's own LoROM $8000-$FFFF space, so an always-open
    // window would shadow game ROM and crash the game.
    is_mk3_bios_path = is_nmi_window
                     & in_par_nmi
                     & (is_fastrom_range | is_lorom_mirror);
    is_game_path     = (is_fastrom_range | is_lorom_mirror)
                     & ~is_mk3_bios_path;
  end else begin
    // No Cheats: cheat interceptor + NMI hook are gated off; full game ROM.
    is_mk3_bios_path = 1'b0;
    is_game_path     = is_fastrom_range | is_lorom_mirror;
  end
end
assign sel_mk3_bios = rom_region & is_mk3_bios_path;
assign sel_game_rom = rom_region & is_game_path;

// BIOS offset: LoROM-style, 4 banks * 32 KB = 128 KB
assign bios_offset = {SNES_ADDR[17:16], SNES_ADDR[14:0]};

endmodule
