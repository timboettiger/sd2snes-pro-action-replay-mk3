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
// Gating: a plain "Control C bit 0 = 0 opens the window" gate is wrong on
// this port because the ROM writes Control C = 0 at $8107 (boot) and $96A3
// (pre-launch) and *never* writes 1 again before the first PAR-NMI exit at
// $B08B (preservaction §5 / table at L339, L1204). So during the entire
// game-boot path Control C = 0 -- a naive gate would leave the window open
// throughout SMW's startup and crash on its $80:B0xx code.
//
// The original Datel IC sidesteps this with hardware-internal state: the
// cart treats the cartridge bus as BIOS-owned only during an actual PAR-NMI
// (from NMI-vector fetch through the handler's exit), not just whenever
// Control C reads 0. We emulate that with two latches:
//
//   - nmi_active: set on the NMI-vector LSB fetch at $00:FFEA in
//     CHEATS_ACTIVE mode (the slot-5/6 hook will redirect to $80:AE12 on
//     the very next fetch, so this is the earliest reliable PAR-NMI entry
//     marker). Cleared after the handler exits, see below.
//
//   - close_timer: armed on the rising edge of Control C bit 0 *while
//     nmi_active is set* -- i.e. the BIOS just wrote $B08B = "I'm done".
//     Holds the window open for 1024 master cycles (~12 us @ 21.477 MHz,
//     ~30 CPU cycles @ FastROM) so the CPU can finish $B08F-$B09D
//     (pla / rep / sep / jmp ($6180)) out of BIOS before the mapper hands
//     the $B0xx region back to the game. When the timer reaches 1 we drop
//     nmi_active and the window snaps shut.
//
// Outside CHEATS_ACTIVE the latches are forced clear -- mode 0 routes
// everything to BIOS via its own path, mode 2 wants the full game ROM.
wire is_nmi_window     = (SNES_ADDR[15:0] >= 16'hAE12)
                       & (SNES_ADDR[15:0] <= 16'hB3F6);

wire is_nmi_vec_fetch  = (SNES_ADDR == 24'h00FFEA);

reg       nmi_active;
reg [9:0] close_timer;
reg       cc_prev_bit0;
always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    nmi_active   <= 1'b0;
    close_timer  <= 10'd0;
    cc_prev_bit0 <= 1'b0;
  end else begin
    cc_prev_bit0 <= control_c[0];

    if (mode != 2'd1) begin
      // Window logic only matters in CHEATS_ACTIVE. Other modes get a
      // hard clear so we never carry stale state across a mode switch.
      nmi_active  <= 1'b0;
      close_timer <= 10'd0;
    end else if (is_nmi_vec_fetch) begin
      // NMI vector LSB fetched in CHEATS_ACTIVE: PAR-NMI handler is about
      // to run. Open the window and stop any in-flight close timer (if a
      // back-to-back NMI fires before the previous close-out finished).
      nmi_active  <= 1'b1;
      close_timer <= 10'd0;
    end else if (control_c[0] & ~cc_prev_bit0 & nmi_active) begin
      // Rising edge of Control C bit 0 during an active PAR-NMI: ROM just
      // wrote $B08B. Start the close burst so $B08F-$B09D can still fetch
      // BIOS.
      close_timer <= 10'd1023;
    end else if (|close_timer) begin
      close_timer <= close_timer - 1'b1;
      if (close_timer == 10'd1) nmi_active <= 1'b0;
    end
  end
end

wire window_open = nmi_active;

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
