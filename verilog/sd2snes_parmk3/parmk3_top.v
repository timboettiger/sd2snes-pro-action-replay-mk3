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

  /* MCU control */
  input  [1:0]  mcu_switch_pos,
  input  mcu_par_menu,
  input  mcu_game_loaded,

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
  output [7:0] leds              // {trainer LED, group LED} from $00:61FE (see parmk3_io)
);

wire [31:0] slot0, slot1, slot2, slot3, slot4, slot5, slot6;
wire [7:0]  control_a, control_c, control_d;
wire        control_b, control_b_just_set;
wire [7:0]  io_dout;
wire        io_hit;
wire [1:0]  fsm_state;
wire        force_cb, clear_cb;
wire        in_par_nmi;       // from u_nmi: 1 while inside the PAR-NMI handler

parmk3_io u_io(
  .CLK(CLK),
  .RST_N(RST_N),
  .SNES_ADDR(SNES_ADDR),
  .cpu_we(cpu_we),
  .cpu_din(bus_data),
  .cpu_dout(io_dout),
  .cpu_hit(io_hit),
  // FSM-side overrides for the Control B sticky latch. The original Datel
  // hardware re-syncs this latch via a cart-side reset whenever the switch
  // moves; sd2snes drives it through these two strobes from parmk3_fsm.
  .force_control_b(force_cb),
  .clear_control_b(clear_cb),
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

assign cheats_active = (effective_mode == 2'd1);

parmk3_mapper u_mapper(
  .CLK(CLK),
  .RST_N(RST_N),
  // The mapper derives effective_mode from (switch_pos, control_b). While the
  // BIOS menu runs control_b==0, so every position resolves to MENU; when the
  // BIOS latches Control B on "Start Game", switch_pos==2 (MENU, the firmware
  // default) resolves to CHEATS_ACTIVE because it is non-zero, so the selected
  // cheats apply automatically. The trainer/group logic runs entirely inside
  // the BIOS PAR-NMI handler (reached via the slot5/6 vector hook) -- the core
  // just lets it run and mirrors its LED output (see parmk3_io $00:61FE snoop).
  //
  // The $xx:AE12-$B3F6 BIOS window is gated by in_par_nmi (driven by
  // parmk3_nmi_hook) so it is open only while the PAR-NMI handler runs and
  // closes again on the handler's final jmp ($6180) at $B09D. control_c is
  // intentionally NOT used as a gate: it would close at $B08B before the
  // handler's exit tail ($B08F-$B09D) is fetched.
  .switch_pos(mcu_switch_pos),
  .control_b(control_b),
  .control_a(control_a),
  .in_par_nmi(in_par_nmi),
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
  .RST_N(RST_N),
  .enable(effective_mode == 2'd1),
  .SNES_ADDR(SNES_ADDR),
  .slot5(slot5),
  .slot6(slot6),
  .hit(nmi_hit),
  .override_byte(nmi_byte),
  .in_par_nmi(in_par_nmi)
);

// Override priority: NMI hook (vector fetch) > intercept (game cheat).
assign bus_override      = nmi_hit | intercept_hit;
assign bus_override_data = nmi_hit ? nmi_byte : intercept_byte;

endmodule
