# Pro Action Replay MK3 for sd2snes / FX Pak Pro

Brings the 1995 Datel Pro Action Replay MK3 cartridge's BIOS-driven cheat
and trainer environment to sd2snes and FX Pak Pro by wrapping arbitrary game 
ROMs with the MK3 BIOS at load time.

The wrapper runs a separate FPGA core (`fpga_parmk3.bi3`) that re-mirrors
the MK3's bank-paged 32 KB SRAM, code slots (`$100000-$10001B`), control
registers (`$10001C`, `$10003C`, `$206000`, `$008000`, `$086000`) and
NMI-vector hijack onto the sd2snes hardware. When active, the sd2snes
cartridge LEDs mirror the two MK3 PCB LEDs plus a mode indicator.

## Required files on the SD card

```
/sd2snes/
├── fpga_parmk3.bi3              ← new: PAR MK3 FPGA core (MK3 hardware)
├── fpga_parmk3.bit              ← new: PAR MK3 FPGA core (MK2 hardware)
├── par_mk3.bin                  ← new: 128 KB Datel MK3 BIOS dump (USER-PROVIDED)
├── fpga_base.bi3 / .bit         ← existing
├── fpga_dsp.bi3 / .bit          ← existing
├── ... (all other existing fpga_*.bi3 / .bit cores)
└── m3nu.bin (MK3) / menu.bin (MK2)  ← updated: menu with PAR MK3 submenu

/sd2snes/saves/
└── {game_name}.srm              ← created automatically on first execution
                                   of the game rom file; persists the 32 KB
                                   MK3 SRAM between sessions.
```

Plus the firmware on the cart itself:
- `firmware.im3` (sd2snes MK3 hardware, LPC1768) — flash via the bootloader
- `firmware.stm` (FX Pak Pro STM32 variant) — flash via the bootloader
- `firmware.img` (sd2snes MK2 hardware) — flash via the bootloader

Check which firmware variant your cart needs with `utils/fxpak.py info` — it
prints the device name ("FXPAK PRO STM32", "sd2snes Mk.II", "sd2snes Mk.III").

## Uploading directly over USB (no qusb2snes)

If your FX Pak Pro is plugged in via USB while you're at the workstation:

```bash
# show device name + firmware version + currently loaded ROM
utils/fxpak.py info

# upload one file
utils/fxpak.py put fpga_parmk3.bi3 /sd2snes/fpga_parmk3.bi3

# bulk-upload everything in ./parmk3-bundle to /sd2snes/
utils/fxpak.py install-parmk3 --bundle ./parmk3-bundle

# reset back into the sd2snes menu (so the new files get picked up)
utils/fxpak.py menu

# boot a specific ROM
utils/fxpak.py boot /myroms/super_mario_world.smc
```

The script talks the native USBINT CDC ACM protocol on
`/dev/cu.usbmodem*` directly; no qusb2snes daemon needed. Use `--dev` to
override the device path if multiple sd2snes / FX Pak units are
connected.

## Where to get `par_mk3.bin`

The 128 KB BIOS image is proprietary Datel code and **not included in
this repository**. You need to dump it yourself from a real Pro Action
Replay MK3 cartridge (the EPROM is socketed; an EPROM programmer or one
of the documented in-circuit dump procedures works).

The expected file size is exactly **131072 bytes (0x20000)**. Other sizes
print a warning and refuse to load.

If `par_mk3.bin` is missing or unreadable, the entire wrapper hides
itself in the menu — no submenu, no main-menu entry, no automatic
routing. You get a normal sd2snes with no behaviour change.

## Using the wrapper

1. **Boot** the sd2snes with the new firmware + cores + `par_mk3.bin`
   on the SD card.
2. Open **Configuration → Pro Action Replay** (the submenu only appears
   when `par_mk3.bin` was found at boot).
3. Set **Enable Pro Action Replay** to **On**. This is the global
   master switch: as long as it is on, every ROM launch goes through
   the MK3 wrapper.
4. Browse to any game ROM, press A. The MK3 BIOS menu appears instead
   of the game booting directly.
5. Configure cheats / trainer parameters / region settings in the BIOS
   menu, then **Start Game** from the BIOS.
6. The game launches with whatever the MK3 BIOS programmed. Cheats,
   trainer, slow-motion and region-adapter behaviour match the real
   Datel hardware (within the limits of the FPGA emulation).
7. To return to the MK3 menu while a game is running: short-reset to
   the sd2snes main menu (default combo / reset button), then select
   the **Pro Action Replay** entry that appears at the top of the
   main menu while the wrapper is active.

## See also

- [openfpga-SNES-pro-action-replay-mk3](https://github.com/timboettiger/openfpga-SNES-pro-action-replay-mk3) — the upstream reference port to the Analogue Pocket
- [action-replay-mk-iii](https://github.com/timboettiger/action-replay-mk-iii) — full BIOS disassembly + PCB reverse engineering
