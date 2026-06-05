`timescale 1 ns / 1 ns
//////////////////////////////////////////////////////////////////////////////////
// parmk3_top.v
//
// Wrapper that bundles the Pro Action Replay MK3 modules into a single block
// instantiated from main.v. Provides the merged ROM_ADDR override and the
// cartridge data-bus override used by the cheat / NMI engines.
//
// External hooks (driven from main.v):
//   - cpu_we is true on bus cycles where the SNES is writing the cartridge.
//   - bus_data is the byte the FPGA would otherwise drive onto SNES_DATA
//     (game ROM, base mapper, etc.); we replace it on intercept hits.
//   - mcu_switch_pos / mcu_par_menu are programmed by the firmware via
//     FPGA_CMD_PARMK3_CTRL (see mcu_cmd.v).
//
// External-bus address translation:
//   - sel_mk3_bios -> rebase to SRAM_PARMK3_BIOS_ADDR + bios_offset
//   - sel_mk3_sram -> rebase to SRAM_PARMK3_MK3RAM_ADDR + sram_offset
//   - otherwise let the base mapper compute the ROM address
//////////////////////////////////////////////////////////////////////////////////
module parmk3_top(
  input  CLK,
  input  RST_N,

  /* SNES bus snoop */
  input  [23:0] SNES_ADDR,
  input  cpu_we,
  input  [7:0]  bus_data,

  /* Controller snoop (live cheat toggle) */
  input  [7:0]  snes_data_in,    // read data, valid at snes_rd_end
  input  snes_rd_start,
  input  snes_rd_end,
  input  snes_wr_end,

  /* MCU control */
  input  [1:0]  mcu_switch_pos,
  input  mcu_par_menu,
  input  mcu_game_loaded,
  input  mcu_trainer_button,     // 0 = Select, 1 = Start

  /* Memory selectors */
  output sel_mk3_bios,
  output sel_game_rom,
  output sel_mk3_sram,
  output [14:0] sram_offset,
  output [16:0] bios_offset,

  /* Override into the SNES data bus */
  output bus_override,
  output [7:0] bus_override_data,

  /* Soft reset & status */
  output snes_soft_reset,
  output [1:0] effective_mode,
  output cheats_active,          // 1 = interceptor actually applying cheats now
  output [7:0] leds,
  output [15:0] pad_dbg,         // DEBUG: raw captured controller-1 state
  output [7:0] rd4219_cnt,       // DEBUG: auto-joypad read count
  output [7:0] rd4016_cnt,       // DEBUG: manual read count
  output [7:0] nmi5_dbg,         // DEBUG: slot5[7:0] = NMI vector LSB
  output [7:0] nmi6_dbg,         // DEBUG: slot6[7:0] = NMI vector MSB
  output [7:0] state_dbg,        // DEBUG: {slot6!=0,slot5!=0,leds[1:0],mode[1:0],ctrlC0,ctrlB}
  output [7:0] nmi_fetch_cnt     // DEBUG: count of $00:FFEA vector fetches
);

wire [31:0] slot0, slot1, slot2, slot3, slot4, slot5, slot6;
wire [7:0]  control_a, control_c, control_d;
wire        control_b, control_b_just_set;
wire [7:0]  io_dout;
wire        io_hit;
wire [1:0]  fsm_state;
wire        force_cb, clear_cb;
// Trainer-combo pulses from the pad snoop (debounced). Currently unconnected:
// the combo effect is held off until the controller capture is verified through
// the clean SPI diagnostic (config group 0x05). pad_dbg/counters still feed it.
wire        cheat_on_pulse, cheat_off_pulse;

parmk3_io u_io(
  .CLK(CLK),
  .RST_N(RST_N),
  .SNES_ADDR(SNES_ADDR),
  .cpu_we(cpu_we),
  .cpu_din(bus_data),
  .cpu_dout(io_dout),
  .cpu_hit(io_hit),
  .slot0(slot0), .slot1(slot1), .slot2(slot2), .slot3(slot3),
  .slot4(slot4), .slot5(slot5), .slot6(slot6),
  .control_a(control_a), .control_b(control_b),
  .control_c(control_c), .control_d(control_d),
  .leds(leds),
  .control_b_just_set(control_b_just_set)
);

parmk3_fsm u_fsm(
  .CLK(CLK),
  .RST_N(RST_N),
  .switch_pos(mcu_switch_pos),
  .par_menu(mcu_par_menu),
  .control_b_pulse(control_b_just_set),
  .game_loaded(mcu_game_loaded),
  .state(fsm_state),
  .snes_soft_reset(snes_soft_reset),
  .force_control_b(force_cb),
  .clear_control_b(clear_cb)
);

// Controller snoop: live cheat toggle via the trainer-button combo.
parmk3_pad_snoop u_pad(
  .CLK(CLK),
  .RST_N(RST_N),
  .SNES_ADDR(SNES_ADDR),
  .SNES_DATA(bus_data),               // raw inout bus (same source parmk3_io uses)
  .rd_start(snes_rd_start),
  .rd_end(snes_rd_end),
  .wr_strobe(snes_wr_end),
  .enable(control_b),                 // only while the game runs
  .trainer_button(mcu_trainer_button),
  .cheat_on_pulse(cheat_on_pulse),
  .cheat_off_pulse(cheat_off_pulse),
  .pad_dbg(pad_dbg),
  .rd4219_cnt(rd4219_cnt),
  .rd4016_cnt(rd4016_cnt)
);

// Live combo DISABLED again: the bus controller-snoop produced noise that the
// debounce couldn't fully reject, so combo_cheat_off false-fired and silenced
// cheats. Until the capture is verified through the clean SPI debug path, the
// interceptor runs purely off the mode and the LED follows that. cheat_on/off
// pulses stay generated (pad_dbg/counters feed the diagnostic) but unconnected.
assign cheats_active = (effective_mode == 2'd1);

// DEBUG: expose the NMI-hook slot bytes and core state so the firmware can read
// (via config 0x05 idx 6/7/8) whether the BIOS programmed the NMI vector hook
// (slot5/6 = "always NMI hook" per the docs) and what the live mode/LED/control
// state is during gameplay.
assign nmi5_dbg  = slot5[7:0];
assign nmi6_dbg  = slot6[7:0];
assign state_dbg = {(slot6 != 32'h0), (slot5 != 32'h0), leds[1:0],
                    effective_mode, control_c[0], control_b};

// DEBUG: count NMI-vector fetches ($00:FFEA reads). If this advances while a
// game runs, the CPU really is fetching the NMI vector and our override fires
// (-> CPU jumps to the slot5/6 address). If it stays put, the hook never gets a
// vector read -> the BIOS PAR-NMI handler can't run. config 0x05 idx 9.
reg [7:0] nmi_fetch_cnt_r;
reg       nmi_hit_q;
always @(posedge CLK or negedge RST_N) begin
  if (!RST_N) begin
    nmi_fetch_cnt_r <= 8'h0;
    nmi_hit_q       <= 1'b0;
  end else begin
    nmi_hit_q <= nmi_hit;
    if (nmi_hit & ~nmi_hit_q) nmi_fetch_cnt_r <= nmi_fetch_cnt_r + 1'b1;
  end
end
assign nmi_fetch_cnt = nmi_fetch_cnt_r;

parmk3_mapper u_mapper(
  .CLK(CLK),
  // Raw MCU switch (proven working): the mapper derives effective_mode from
  // (switch_pos, control_b). While the BIOS menu runs control_b==0 so every
  // position resolves to MENU; when the BIOS latches Control B on "Start Game",
  // switch_pos==2 (MENU, the firmware default) resolves to CHEATS_ACTIVE because
  // it is non-zero, so selected cheats apply automatically. Live combo toggle is
  // re-enabled here once the controller capture (pad_dbg) is verified.
  .switch_pos(mcu_switch_pos),
  .control_b(control_b),
  .control_a(control_a),
  .SNES_ADDR(SNES_ADDR),
  .sel_mk3_bios(sel_mk3_bios),
  .sel_game_rom(sel_game_rom),
  .sel_mk3_sram(sel_mk3_sram),
  .sram_offset(sram_offset),
  .bios_offset(bios_offset),
  .effective_mode(effective_mode)
);

wire intercept_hit;
wire [7:0] intercept_byte;
parmk3_intercept u_intercept(
  .CLK(CLK),
  .enable(effective_mode == 2'd1),
  .SNES_ADDR(SNES_ADDR),
  .slot0(slot0), .slot1(slot1), .slot2(slot2), .slot3(slot3), .slot4(slot4),
  .hit(intercept_hit),
  .override_byte(intercept_byte)
);

wire nmi_hit;
wire [7:0] nmi_byte;
parmk3_nmi_hook u_nmi(
  .CLK(CLK),
  .enable(effective_mode == 2'd1),
  .SNES_ADDR(SNES_ADDR),
  .slot5(slot5),
  .slot6(slot6),
  .hit(nmi_hit),
  .override_byte(nmi_byte)
);

// Override priority: NMI hook (vector fetch) > intercept (game cheat).
assign bus_override      = nmi_hit | intercept_hit;
assign bus_override_data = nmi_hit ? nmi_byte : intercept_byte;

endmodule
