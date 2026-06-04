`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_pad_snoop.v
//
// Controller-1 button snoop for the PAR MK3 wrapper. The sd2snes in-game NMI
// hook (which normally turns a button combo into CMD_ENABLE/DISABLE_CHEATS) is
// disabled while the MK3 BIOS owns the NMI vector, so the wrapper has to read
// the pad straight off the SNES bus to offer a live cheat toggle.
//
// Two snoop paths cover both controller-read styles a game (or the BIOS NMI)
// may use; both yield the same canonical 16-bit layout:
//
//   bit15 B   bit14 Y   bit13 Select bit12 Start
//   bit11 Up  bit10 Dn  bit9  Left   bit8  Right
//   bit7  A   bit6  X    bit5  L      bit4  R     (bits 3:0 = controller sig)
//
//   * Auto-joypad ($4218 = JOY1L, $4219 = JOY1H): latched directly on read.
//   * Manual ($4016): the standard 16-iteration serial read loop; bit 0 of each
//     read is shifted in MSB-first, published after the 16th read. The MK3 BIOS
//     itself polls this way (disassembly $80/AE5B..AE8F).
//
// Combo (matches the real MK3 "TRAINER-SELECT" convention — Select by default,
// switchable to Start when the game already uses Select):
//
//   trainer + L  -> cheat_on_pulse   (-> switch = CHEATS_ACTIVE)
//   trainer + R  -> cheat_off_pulse  (-> switch = NO_CHEATS)
//
// Pulses are edge-triggered (one cycle on press), so holding the combo toggles
// exactly once. `enable` gates detection to game execution (control_b), keeping
// the BIOS menu's own controller handling untouched.
//////////////////////////////////////////////////////////////////////////////////
module parmk3_pad_snoop(
  input  CLK,
  input  RST_N,
  input  [23:0] SNES_ADDR,
  input  [7:0]  SNES_DATA,        // SNES_DATA_IN, valid at rd_strobe
  input  rd_strobe,               // SNES_RD_end (read data settled)
  input  wr_strobe,               // SNES_WR_end (for the $4016 latch write)
  input  enable,                  // detect only while the game runs (control_b)
  input  trainer_button,          // 0 = Select, 1 = Start
  output reg cheat_on_pulse,
  output reg cheat_off_pulse
);

// Bank-agnostic decode of the B-bus controller registers ($00/$80 mirrors).
wire sel_4016 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04016);
wire sel_4218 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04218);
wire sel_4219 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04219);

reg [15:0] pad;          // canonical current state (auto path + published manual)
reg [15:0] manual_sr;    // in-flight $4016 shift register
reg [4:0]  manual_cnt;   // reads since the latest $4016 latch write

always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    pad        <= 16'h0;
    manual_sr  <= 16'h0;
    manual_cnt <= 5'h0;
  end else begin
    // --- auto-joypad snoop: latch each byte as the game reads it ---
    if (rd_strobe & sel_4219) pad[15:8] <= SNES_DATA;
    if (rd_strobe & sel_4218) pad[7:0]  <= SNES_DATA;

    // --- manual $4016 snoop ---
    if (wr_strobe & sel_4016) begin
      // CPU strobes the latch before the serial read loop.
      manual_cnt <= 5'h0;
      manual_sr  <= 16'h0;
    end else if (rd_strobe & sel_4016) begin
      manual_sr <= {manual_sr[14:0], SNES_DATA[0]};
      if (manual_cnt == 5'd15) begin
        // 16th read completes the word; publish in canonical layout.
        pad        <= {manual_sr[14:0], SNES_DATA[0]};
        manual_cnt <= 5'h0;
      end else begin
        manual_cnt <= manual_cnt + 1'b1;
      end
    end
  end
end

// Combo decode. A button bit is 1 while held (active-high in this layout).
wire trainer_held = trainer_button ? pad[12] : pad[13];  // Start : Select
wire l_held       = pad[5];
wire r_held       = pad[4];
wire combo_on     = enable & trainer_held & l_held & ~r_held;
wire combo_off    = enable & trainer_held & r_held & ~l_held;

reg combo_on_q, combo_off_q;
always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    combo_on_q      <= 1'b0;
    combo_off_q     <= 1'b0;
    cheat_on_pulse  <= 1'b0;
    cheat_off_pulse <= 1'b0;
  end else begin
    combo_on_q      <= combo_on;
    combo_off_q     <= combo_off;
    cheat_on_pulse  <= combo_on  & ~combo_on_q;   // rising edge only
    cheat_off_pulse <= combo_off & ~combo_off_q;
  end
end

endmodule
