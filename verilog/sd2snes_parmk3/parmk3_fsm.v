`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_fsm.v
//
// 3-state finite-state machine for the PAR MK3 wrapper. On the original
// hardware this is driven by the physical 3-way cartridge switch; on sd2snes
// the MCU programs `switch_pos` via FPGA_CMD_PARMK3_CTRL.
//
//   State 0 = MK3_MENU       (default at power-on)
//   State 1 = CHEATS_ACTIVE  (game running with cheat interception)
//   State 2 = NO_CHEATS      (game running without cheats)
//
// Ported from openfpga-SNES-pro-action-replay-mk3/rtl/chip/mk3/mk3_switch_fsm.sv.
// snes_soft_reset is OR'd into the host core reset so cross-mode transitions
// give the CPU a clean RES pulse.
//////////////////////////////////////////////////////////////////////////////////
module parmk3_fsm(
  input  CLK,
  input  RST_N,
  input  [1:0]  switch_pos,
  input  par_menu,                 // forces back to MK3_MENU (e.g. controller combo)
  input  control_b_pulse,
  input  game_loaded,
  output [1:0]  state,
  output        snes_soft_reset,
  output        force_control_b,
  output        clear_control_b
);

parameter RESET_HOLD_CYCLES = 256; // ~12 µs @ 21.477 MHz

localparam S_MK3_MENU      = 2'd0;
localparam S_CHEATS_ACTIVE = 2'd1;
localparam S_NO_CHEATS     = 2'd2;

reg [1:0] state_r;
reg [1:0] switch_prev;
reg [8:0] reset_counter;           // wide enough for default 256
reg       force_cb_r;
reg       clear_cb_r;

wire switch_changed = (switch_pos != switch_prev);

always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    state_r       <= S_MK3_MENU;
    switch_prev   <= 2'd2;
    reset_counter <= 9'd0;
    force_cb_r    <= 1'b0;
    clear_cb_r    <= 1'b0;
  end else begin
    if (|reset_counter) reset_counter <= reset_counter - 1'b1;
    force_cb_r  <= 1'b0;
    clear_cb_r  <= 1'b0;
    switch_prev <= switch_pos;

    if (par_menu) begin
      if (state_r != S_MK3_MENU) begin
        state_r       <= S_MK3_MENU;
        reset_counter <= RESET_HOLD_CYCLES[8:0];
        clear_cb_r    <= 1'b1;
      end
    end
    else if (control_b_pulse) begin
      case (switch_pos)
        2'd1: state_r <= S_CHEATS_ACTIVE;
        2'd0: state_r <= S_NO_CHEATS;
        default: ;
      endcase
    end
    else if (switch_changed) begin
      case (switch_pos)
        2'd2: begin
          if (state_r != S_MK3_MENU) begin
            state_r       <= S_MK3_MENU;
            reset_counter <= RESET_HOLD_CYCLES[8:0];
            clear_cb_r    <= 1'b1;
          end
        end
        2'd1: begin
          if ((state_r == S_MK3_MENU) & game_loaded) begin
            state_r       <= S_CHEATS_ACTIVE;
            reset_counter <= RESET_HOLD_CYCLES[8:0];
            force_cb_r    <= 1'b1;
          end
          else if (state_r == S_NO_CHEATS) begin
            state_r <= S_CHEATS_ACTIVE;
          end
        end
        2'd0: begin
          if ((state_r == S_MK3_MENU) & game_loaded) begin
            state_r       <= S_NO_CHEATS;
            reset_counter <= RESET_HOLD_CYCLES[8:0];
            force_cb_r    <= 1'b1;
          end
          else if (state_r == S_CHEATS_ACTIVE) begin
            state_r <= S_NO_CHEATS;
          end
        end
        default: ;
      endcase
    end
  end
end

assign state           = state_r;
assign snes_soft_reset = |reset_counter;
assign force_control_b = force_cb_r;
assign clear_control_b = clear_cb_r;

endmodule
