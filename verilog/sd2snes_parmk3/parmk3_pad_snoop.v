`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_pad_snoop.v
//
// Controller-1 button snoop for the PAR MK3 wrapper. The sd2snes in-game NMI
// hook (which normally turns a button combo into CMD_ENABLE/DISABLE_CHEATS) is
// disabled while the MK3 BIOS owns the NMI vector, so the wrapper reads the pad
// straight off the SNES bus to offer a live cheat toggle.
//
// TIMING: SNES_ADDR, SNES_DATA and the read strobe sit at different points in
// main.v's input pipeline. Capturing data and decoding the address at the same
// edge mis-aligns them (the address has already advanced), which yielded pure
// bus noise. So we latch *which* register is being read at SNES_RD_start (when
// the address is valid, matching main.v's own $4016 snoop) and sample the data
// at SNES_RD_end (when the SNES has driven it). SNES_DATA is the raw inout bus,
// the same signal parmk3_io samples for writes.
//
// Canonical 16-bit layout (both read styles converge on this):
//   bit15 B   bit14 Y   bit13 Select bit12 Start
//   bit11 Up  bit10 Dn  bit9  Left   bit8  Right
//   bit7  A   bit6  X    bit5  L      bit4  R     (bits 3:0 = controller sig)
//
//   * Auto-joypad ($4218 = JOY1L, $4219 = JOY1H): latched per read.
//   * Manual ($4016): standard 16-iteration serial read; bit 0 shifted in
//     MSB-first, published after the 16th read. The MK3 BIOS polls this way.
//
// Combo (real MK3 "TRAINER-SELECT": Select default, switchable to Start):
//   trainer + L -> cheat_on_pulse ; trainer + R -> cheat_off_pulse
// Edge-triggered; gated by `enable` (control_b) to game execution.
//
// Debug: pad_dbg exposes the captured state; rd4219_cnt / rd4016_cnt count how
// often each read style fires, so we can tell which one a given game uses.
//////////////////////////////////////////////////////////////////////////////////
module parmk3_pad_snoop(
  input  CLK,
  input  RST_N,
  input  [23:0] SNES_ADDR,
  input  [7:0]  SNES_DATA,        // raw inout bus
  input  rd_start,                // SNES_RD_start (address valid)
  input  rd_end,                  // SNES_RD_end (read data settled)
  input  wr_strobe,               // SNES_WR_end (for the $4016 latch write)
  input  enable,                  // detect only while the game runs (control_b)
  input  trainer_button,          // 0 = Select, 1 = Start
  output reg cheat_on_pulse,
  output reg cheat_off_pulse,
  output [15:0] pad_dbg,          // DEBUG: captured controller-1 state
  output [7:0]  rd4219_cnt,       // DEBUG: auto-joypad read count
  output [7:0]  rd4016_cnt        // DEBUG: manual read count
);

// Bank-agnostic decode of the controller registers ($00/$80 mirrors).
wire sel_4016 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04016);
wire sel_4218 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04218);
wire sel_4219 = ({SNES_ADDR[22], SNES_ADDR[15:0]} == 17'h04219);

reg [15:0] pad;
reg [15:0] manual_sr;
reg [4:0]  manual_cnt;
reg [7:0]  c4219, c4016;
// Address latched at read-start, consumed at read-end (keeps addr/data aligned).
reg cap_4016, cap_4218, cap_4219;

assign pad_dbg    = pad;
assign rd4219_cnt = c4219;
assign rd4016_cnt = c4016;

always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    pad        <= 16'h0;
    manual_sr  <= 16'h0;
    manual_cnt <= 5'h0;
    c4219      <= 8'h0;
    c4016      <= 8'h0;
    cap_4016   <= 1'b0;
    cap_4218   <= 1'b0;
    cap_4219   <= 1'b0;
  end else begin
    // $4016 latch write begins a fresh manual read sequence.
    if (wr_strobe & sel_4016) begin
      manual_cnt <= 5'h0;
      manual_sr  <= 16'h0;
    end

    // Latch which register the CPU is reading while the address is valid.
    if (rd_start) begin
      cap_4016 <= sel_4016;
      cap_4218 <= sel_4218;
      cap_4219 <= sel_4219;
    end

    // Sample the data once the SNES has driven it.
    if (rd_end) begin
      if (cap_4219) begin
        pad[15:8] <= SNES_DATA;
        c4219     <= c4219 + 1'b1;
      end
      if (cap_4218) begin
        pad[7:0]  <= SNES_DATA;
      end
      if (cap_4016) begin
        manual_sr <= {manual_sr[14:0], SNES_DATA[0]};
        c4016     <= c4016 + 1'b1;
        if (manual_cnt == 5'd15) begin
          pad        <= {manual_sr[14:0], SNES_DATA[0]};
          manual_cnt <= 5'h0;
        end else begin
          manual_cnt <= manual_cnt + 1'b1;
        end
      end
      cap_4016 <= 1'b0;
      cap_4218 <= 1'b0;
      cap_4219 <= 1'b0;
    end
  end
end

// Combo decode (active-high: 1 = held).
wire trainer_held = trainer_button ? pad[12] : pad[13];  // Start : Select
wire l_held       = pad[5];
wire r_held       = pad[4];
wire combo_on     = enable & trainer_held & l_held & ~r_held;
wire combo_off    = enable & trainer_held & r_held & ~l_held;

// Debounce: the combo must hold steady for ~49 ms (2^20 @ 21.477 MHz) before it
// fires, and fires exactly once until released. A captured-bus glitch never
// stays valid that long, so noise on the snoop cannot produce a false toggle;
// a real held combo easily does. Counters reset the instant the combo drops.
localparam [19:0] HOLD = 20'hFFFFE;
reg [19:0] on_cnt, off_cnt;
always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    on_cnt          <= 20'h0;
    off_cnt         <= 20'h0;
    cheat_on_pulse  <= 1'b0;
    cheat_off_pulse <= 1'b0;
  end else begin
    cheat_on_pulse  <= 1'b0;
    cheat_off_pulse <= 1'b0;
    if (combo_on) begin
      if (on_cnt != 20'hFFFFF) begin
        on_cnt <= on_cnt + 1'b1;
        if (on_cnt == HOLD) cheat_on_pulse <= 1'b1;  // single pulse at threshold
      end
    end else begin
      on_cnt <= 20'h0;
    end
    if (combo_off) begin
      if (off_cnt != 20'hFFFFF) begin
        off_cnt <= off_cnt + 1'b1;
        if (off_cnt == HOLD) cheat_off_pulse <= 1'b1;
      end
    end else begin
      off_cnt <= 20'h0;
    end
  end
end

endmodule
