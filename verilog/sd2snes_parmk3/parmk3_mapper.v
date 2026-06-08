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
  input  [7:0] control_c,          // bit 0 gates the PAR-NMI BIOS window
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
// Gating: the BIOS opens the window by writing Control C = 0 on PAR-NMI
// entry ($AE2B) and closes it again with Control C = 1 on exit ($B08B).
// Game-side code (e.g. Super Mario World) reads its own $80:B0xx region
// while the game's main loop runs -- so the window MUST be closed there,
// otherwise the CPU fetches BIOS bytes instead of game code and the game
// crashes before VBlank.
//
// The OpenFPGA reference (mk3_mapper.sv:6299b9a) drops the Control C gate
// and leaves the window always-open during CHEATS_ACTIVE because the ROM
// writes Control C = 1 at $B08B *before* the NMI exit finishes ($B08F-$B09D
// still need BIOS bytes -- stack pops + jmp ($6180)). That trade-off
// breaks games that legitimately use the $B000-$B3F6 region (SMW does).
//
// Our fix: re-introduce the gate, but delay the closing edge by 1024
// master cycles (~12 us @ 21.477 MHz, ~32 CPU cycles @ 2.68 MHz FastROM)
// so the last 18 BIOS bytes after the $B08B Control C = 1 write are still
// fetched as BIOS. After the delay expires the window snaps shut and the
// game's main loop sees its own $B0xx region again. This matches the
// observed behaviour of the original Datel hardware (PAR-NMI handler runs
// fully, host game keeps its address space) without trading off
// compatibility with games that use the window range.
wire is_nmi_window     = (SNES_ADDR[15:0] >= 16'hAE12)
                       & (SNES_ADDR[15:0] <= 16'hB3F6);

// Delayed closing of the window after Control C bit 0 rises 0 -> 1. See the
// rationale block above for why a plain combinational gate is insufficient.
// 1024 master cycles is generous: 18 bytes * (FastROM 6 master cycles per
// CPU cycle * ~4 CPU cycles per byte) = ~432 master cycles, so 1024 has
// >2x margin even if the ROM ever runs in SlowROM mode at this point.
reg [9:0] cc_close_timer;
reg       cc_prev_bit0;
always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    cc_close_timer <= 10'd0;
    cc_prev_bit0   <= 1'b0;
  end else begin
    cc_prev_bit0 <= control_c[0];
    if (control_c[0] & ~cc_prev_bit0) begin
      // Rising edge of Control C bit 0: BIOS just wrote $B08B (signaling
      // "close the window"). Hold the window open for one more burst so the
      // CPU can fetch $B08F-$B09D (pla / rep / sep / jmp ($6180)) before
      // the mapper hands the $B0xx region back to the game.
      cc_close_timer <= 10'd1023;
    end else if (|cc_close_timer) begin
      cc_close_timer <= cc_close_timer - 1'b1;
    end
  end
end

// Window is open while the BIOS owns the bus (Control C bit 0 = 0), and for
// the trailing delay window after it writes Control C = 1.
wire window_open = ~control_c[0] | (|cc_close_timer);

reg is_mk3_bios_path;
reg is_game_path;
always @* begin
  if (mode == 2'd0) begin
    is_mk3_bios_path = is_fastrom_range | (is_lorom_mirror & ~control_a[4]);
    is_game_path     = is_lorom_mirror & control_a[4];
  end else if (mode == 2'd1) begin
    // Cheats Active: game ROM normally, but the PAR-NMI handler window
    // ($xx:AE12-$B3F6) shows BIOS while window_open (see rationale block
    // above for the Control C / delayed-close logic).
    is_mk3_bios_path = is_nmi_window
                     & (is_fastrom_range | is_lorom_mirror)
                     & window_open;
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
