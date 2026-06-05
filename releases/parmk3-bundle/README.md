# PAR MK3 Bundle — current state

What's in this directory:

| File | Source | Notes |
|---|---|---|
| `menu.bin`  | snescom + sneslink build from `snes/` | sd2snes Mk.II menu binary, **includes** the Configuration → Pro Action Replay submenu and the in-game cheat routing changes |
| `m3nu.bin`  | snescom + sneslink build from `snes/` | sd2snes Mk.III / FX Pak Pro variant of the same menu |

## Still missing (need to be built on a real Linux host)

| File | Built by | Why not here |
|---|---|---|
| `fpga_parmk3.bi3` | `make -C verilog/sd2snes_parmk3 mk3` (Quartus 18.1, Cyclone IV E EP4CE15F17C8) | Quartus 18.1 segfaults inside Intel TBB on the Synology Docker host used for this iteration. See `utils/docker/Dockerfile.quartus18` header for the trace. |
| `fpga_parmk3.bit` | same, `mk2` target | needs Xilinx ISE 14.7 — not yet containerised in this repo |
| `fpga_mini.bi3` | `make -C verilog/sd2snes_mini mk3` | same Quartus issue |
| `firmware.stm` | `make -C src CONFIG=config-mk3-stm32` | depends on `fpga_mini.bi3` (embedded as `cfgware.h`) |
| `firmware.im3` | `make -C src CONFIG=config-mk3` | same |
| `firmware.img` | `make -C src CONFIG=config-mk2` | same |
| `par_mk3.bin` | user-provided 128 KB BIOS dump | proprietary Datel code, not in this repo |

## Building the missing pieces on a Linux host

```bash
# 1. install Quartus Prime Lite 18.1 (Cyclone IV E is in the default device pack)
#    https://downloads.intel.com/akdlm/software/acdsinst/18.1std/625/ib_installers/QuartusLiteSetup-18.1.0.625-linux.run

# 2. build the two FPGA cores
cd verilog/sd2snes_parmk3 && make mk3
cd ../sd2snes_mini       && make mk3

# 3. install the ARM cross toolchain + snescom and build the firmware
sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi libboost-all-dev gawk
# snescom: https://bisqwit.iki.fi/src/arch/snescom-1.8.1.1.tar.gz
make -C utils rle                          # compiles utils/rle (used by FPGA Makefiles)
make -C snes                               # menu.bin + m3nu.bin (already pre-built here)
make -C src CONFIG=config-mk3-stm32        # firmware.stm  (FX Pak Pro STM32)
make -C src CONFIG=config-mk3              # firmware.im3  (sd2snes MK.III LPC1768)
```

The `utils/docker/Dockerfile.firmware` produces a container that already
has `gcc-arm-none-eabi`, `snescom`, `sneslink`, `gawk` and the libboost
preinstalled — if Docker is available it's a one-shot:

```bash
docker build -t sd2snes-firmware -f utils/docker/Dockerfile.firmware utils/docker/
docker run --rm -v "$PWD":/work -w /work sd2snes-firmware bash -c \
  "make -C utils rle && make -C snes && make -C src CONFIG=config-mk3-stm32"
```

The `Dockerfile.quartus18` is included but only works reliably on a real
Linux host or a non-Synology Docker host; the Synology DSM kernel
(4.4-vintage) breaks Quartus' internal TBB allocator.

## Uploading once the bundle is complete

```bash
# all files in ./parmk3-bundle/ go onto the SD card under /sd2snes/
utils/fxpak.py install-parmk3 --bundle releases/parmk3-bundle

# then reset into the menu so the new files get picked up
utils/fxpak.py menu
```

`install-parmk3` only uploads files that actually exist in the bundle;
missing pieces are skipped, the message lists what was sent.
