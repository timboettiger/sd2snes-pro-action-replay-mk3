#!/usr/bin/env python3
"""
fxpak.py -- Direct USB CDC control for FX Pak Pro / sd2snes.

Speaks the native USBINT protocol over /dev/cu.usbmodem* without going through
qusb2snes. Implemented protocol subset:

  info                    Read firmware version, device name, current ROM
  reset                   Reset the SNES side (keep current ROM)
  menu                    Reset back to the sd2snes / FX Pak Pro menu
  boot <path-on-card>     Boot the named ROM (path under /sd2snes/, e.g. /myrom.smc)
  ls <dir>                List files under <dir> on the SD card
  put <local> <remote>    Upload a local file to the SD card (overwrites)
  get <remote> <local>    Download a file from the SD card
  install-parmk3 [dir]    Convenience: upload the parmk3 bundle. Looks for
                          fpga_parmk3.bi3 (and .bit), m3nu.bin, firmware.im3,
                          par_mk3.bin in the given directory and copies each
                          that exists to /sd2snes/<name>. par_mk3.bin is the
                          MK3 BIOS dump and MUST be supplied by the user --
                          it is not in this repository.

Protocol summary (extracted from src/usbinterface.{c,h}):
  Command is 512 bytes:
    [0..3]   'USBA'
    [4]      opcode (GET=0 PUT=1 LS=4 RESET=8 BOOT=9 INFO=11 MENU_RESET=12 ...)
    [5]      space  (FILE=0 SNES=1 ...)
    [6]      flags  (NORESP=0x40, 64BDATA=0x80, ...)
    [252..255] U32BE total transfer size (PUT/GET)
    [256..]  C-string filename (SP_FILE) or U32BE offset (SP_SNES)
  PUT streams data in 512-byte blocks after the command.
  Response (when not NORESP) is 512 bytes starting with 'USBA' and opcode 0x0f.

Default device path is /dev/cu.usbmodemDEMO000000001 -- the LPC1768 USB CDC
serial number assigned by the sd2snes firmware. Override with --dev when the
sd2snes shows up under a different /dev/cu.usbmodem* name.

No external Python deps; only os/struct/argparse from the standard library.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time
from typing import Optional


# ---- Protocol constants -----------------------------------------------------

OP_GET, OP_PUT, OP_VGET, OP_VPUT = 0, 1, 2, 3
OP_LS, OP_MKDIR, OP_RM, OP_MV    = 4, 5, 6, 7
OP_RESET, OP_BOOT, OP_POWER_CYCLE, OP_INFO = 8, 9, 10, 11
OP_MENU_RESET = 12
OP_STREAM     = 13
OP_TIME       = 14
OP_RESPONSE   = 0x0f

SP_FILE, SP_SNES, SP_MSU, SP_CMD, SP_CONFIG, SP_CFG = range(6)

F_NONE     = 0x00
F_SKIPRESET = 0x01
F_ONLYRESET = 0x02
F_NORESP   = 0x40
F_64BDATA  = 0x80

BLOCK = 512
RESP_TIMEOUT = 3.0   # seconds


# ---- Low-level transport ---------------------------------------------------

def open_dev(path: str) -> int:
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    return fd


def write_all(fd: int, data: bytes) -> None:
    total = 0
    while total < len(data):
        n = os.write(fd, data[total:])
        if n <= 0:
            raise IOError("write returned 0/negative")
        total += n


def read_exact(fd: int, n: int, timeout: float = RESP_TIMEOUT) -> bytes:
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while len(buf) < n:
        remaining = n - len(buf)
        # nonblocking-ish: just read what's available, sleep on empty
        try:
            chunk = os.read(fd, remaining)
        except BlockingIOError:
            chunk = b''
        if chunk:
            buf += chunk
        else:
            if time.monotonic() > deadline:
                raise TimeoutError(f"read_exact: got {len(buf)} of {n} bytes")
            time.sleep(0.01)
    return bytes(buf)


def build_cmd(
    opcode: int,
    space: int = SP_FILE,
    flags: int = F_NONE,
    filename: Optional[str] = None,
    address: int = 0,
    size: int = 0,
) -> bytes:
    cmd = bytearray(BLOCK)
    cmd[0:4] = b'USBA'
    cmd[4] = opcode
    cmd[5] = space
    cmd[6] = flags
    # size at 252..255 (U32BE)
    struct.pack_into('>I', cmd, 252, size & 0xFFFFFFFF)
    if filename is not None:
        # filename starts at offset 256; firmware reads it as a null-terminated string
        fn = filename.encode('ascii', errors='replace')
        if len(fn) > BLOCK - 256 - 1:
            raise ValueError(f"filename too long: {filename!r}")
        cmd[256:256 + len(fn)] = fn
        # leave a 0 byte after; bytearray is zero-initialised so the terminator is implicit
    elif space != SP_FILE:
        # offset at 256..259 (U32BE) for non-FILE spaces
        struct.pack_into('>I', cmd, 256, address & 0xFFFFFFFF)
    return bytes(cmd)


def send_cmd(fd: int, **kw) -> None:
    write_all(fd, build_cmd(**kw))


def recv_response(fd: int) -> bytes:
    resp = read_exact(fd, BLOCK)
    if resp[:4] != b'USBA':
        raise IOError(f"bad response magic: {resp[:4]!r}")
    if resp[4] != OP_RESPONSE:
        raise IOError(f"bad response opcode: 0x{resp[4]:02x}")
    return resp


# ---- High-level commands ---------------------------------------------------

def cmd_info(fd: int) -> dict:
    send_cmd(fd, opcode=OP_INFO, space=SP_SNES, flags=F_NONE)
    resp = recv_response(fd)
    info = {
        'feature_flags': struct.unpack_from('<H', resp, 6)[0],
        'state_flags':   struct.unpack_from('<H', resp, 10)[0],
        'rom_name':      resp[16:256].split(b'\x00', 1)[0].decode('ascii', 'replace'),
        'fwver_magic':   struct.unpack_from('>I', resp, 256)[0],
        'fwver_string':  resp[260:324].split(b'\x00', 1)[0].decode('ascii', 'replace'),
        'device_name':   resp[324:388].split(b'\x00', 1)[0].decode('ascii', 'replace'),
    }
    return info


def cmd_reset(fd: int) -> None:
    send_cmd(fd, opcode=OP_RESET, space=SP_SNES, flags=F_NORESP)


def cmd_menu(fd: int) -> None:
    send_cmd(fd, opcode=OP_MENU_RESET, space=SP_SNES, flags=F_NORESP)


def cmd_boot(fd: int, remote_path: str) -> None:
    send_cmd(fd, opcode=OP_BOOT, space=SP_FILE, flags=F_NORESP, filename=remote_path)


def cmd_put(fd: int, local_path: str, remote_path: str) -> int:
    with open(local_path, 'rb') as f:
        data = f.read()
    size = len(data)
    send_cmd(fd, opcode=OP_PUT, space=SP_FILE, flags=F_NORESP,
             filename=remote_path, size=size)
    # firmware now expects size bytes in BLOCK chunks; the last chunk is padded
    sent = 0
    while sent < size:
        chunk = data[sent:sent + BLOCK]
        if len(chunk) < BLOCK:
            chunk = chunk + b'\x00' * (BLOCK - len(chunk))
        write_all(fd, chunk)
        sent += BLOCK
    return size


def cmd_get(fd: int, remote_path: str, local_path: str) -> int:
    send_cmd(fd, opcode=OP_GET, space=SP_FILE, flags=F_NONE, filename=remote_path)
    resp = recv_response(fd)
    if resp[5] != 0:
        raise IOError(f"GET failed, error=0x{resp[5]:02x}")
    size = struct.unpack_from('>I', resp, 252)[0]
    blocks = (size + BLOCK - 1) // BLOCK
    got = bytearray()
    for _ in range(blocks):
        got += read_exact(fd, BLOCK)
    got = bytes(got[:size])
    with open(local_path, 'wb') as f:
        f.write(got)
    return size


def cmd_ls(fd: int, remote_dir: str) -> list:
    send_cmd(fd, opcode=OP_LS, space=SP_FILE, flags=F_NONE, filename=remote_dir)
    resp = recv_response(fd)
    if resp[5] != 0:
        raise IOError(f"LS failed, error=0x{resp[5]:02x}")
    size = struct.unpack_from('>I', resp, 252)[0]
    blocks = (size + BLOCK - 1) // BLOCK
    raw = bytearray()
    for _ in range(blocks):
        raw += read_exact(fd, BLOCK)
    raw = bytes(raw[:size])
    # Format from firmware: [type:1][name\0]...  type 0=dir, 1=file, 2=end
    entries = []
    i = 0
    while i < len(raw):
        t = raw[i]
        i += 1
        if t == 2 or i >= len(raw):
            break
        end = raw.find(b'\x00', i)
        if end < 0:
            break
        name = raw[i:end].decode('ascii', 'replace')
        i = end + 1
        entries.append(('dir' if t == 0 else 'file', name))
    return entries


# ---- Device auto-detect ----------------------------------------------------

import glob

def autodetect_dev() -> Optional[str]:
    """Pick the first /dev/cu.usbmodem* that looks like an sd2snes / FX Pak.

    macOS exposes USB CDC devices as /dev/cu.usbmodem<serial>. There is no
    cheap way to distinguish an FX Pak from any other CDC ACM device without
    poking it; we just return the first match and let the actual `info`
    call fail loudly if it is the wrong device.
    """
    candidates = sorted(glob.glob('/dev/cu.usbmodem*'))
    return candidates[0] if candidates else None


# ---- CLI -------------------------------------------------------------------

DEFAULT_DEV = autodetect_dev() or '/dev/cu.usbmodem'


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split('\n\n', 1)[0])
    p.add_argument('--dev', default=DEFAULT_DEV, help=f'serial device (default: {DEFAULT_DEV})')
    sub = p.add_subparsers(dest='cmd', required=True)

    sub.add_parser('info')
    sub.add_parser('reset')
    sub.add_parser('menu')

    p_boot = sub.add_parser('boot')
    p_boot.add_argument('remote', help='ROM path on the card, e.g. /myrom.smc')

    p_ls = sub.add_parser('ls')
    p_ls.add_argument('remote', nargs='?', default='/')

    p_put = sub.add_parser('put')
    p_put.add_argument('local')
    p_put.add_argument('remote')

    p_get = sub.add_parser('get')
    p_get.add_argument('remote')
    p_get.add_argument('local')

    p_inst = sub.add_parser('install-parmk3', help='upload the PAR MK3 bundle to /sd2snes/')
    p_inst.add_argument('--bundle', default='./parmk3-bundle')

    args = p.parse_args()

    if not os.path.exists(args.dev):
        print(f"error: device {args.dev} does not exist (FX Pak not connected?)", file=sys.stderr)
        return 2

    fd = open_dev(args.dev)
    try:
        if args.cmd == 'info':
            info = cmd_info(fd)
            print(f"Device:    {info['device_name']}")
            print(f"Firmware:  {info['fwver_string']} (magic 0x{info['fwver_magic']:08x})")
            print(f"Current:   {info['rom_name'] or '(menu)'}")
            print(f"Features:  0x{info['feature_flags']:04x}")
            print(f"State:     0x{info['state_flags']:04x}")
        elif args.cmd == 'reset':
            cmd_reset(fd)
            print("reset sent")
        elif args.cmd == 'menu':
            cmd_menu(fd)
            print("menu reset sent")
        elif args.cmd == 'boot':
            cmd_boot(fd, args.remote)
            print(f"boot {args.remote} sent")
        elif args.cmd == 'ls':
            for kind, name in cmd_ls(fd, args.remote):
                print(f"{kind:4} {name}")
        elif args.cmd == 'put':
            n = cmd_put(fd, args.local, args.remote)
            print(f"put {args.local} -> {args.remote}  ({n} bytes)")
        elif args.cmd == 'get':
            n = cmd_get(fd, args.remote, args.local)
            print(f"get {args.remote} -> {args.local}  ({n} bytes)")
        elif args.cmd == 'install-parmk3':
            bundle = args.bundle
            wanted = [
                ('fpga_parmk3.bi3', '/sd2snes/fpga_parmk3.bi3'),
                ('fpga_parmk3.bit', '/sd2snes/fpga_parmk3.bit'),
                ('m3nu.bin',        '/sd2snes/m3nu.bin'),
                ('menu.bin',        '/sd2snes/menu.bin'),
                ('firmware.im3',    '/sd2snes/firmware.im3'),
                ('firmware.img',    '/sd2snes/firmware.img'),
                ('par_mk3.bin',     '/sd2snes/par_mk3.bin'),
            ]
            uploaded = 0
            for fname, dest in wanted:
                local = os.path.join(bundle, fname)
                if os.path.exists(local):
                    n = cmd_put(fd, local, dest)
                    print(f"put {fname:24} -> {dest}  ({n} bytes)")
                    uploaded += 1
                else:
                    print(f"skip {fname:23} (not in {bundle})")
            print(f"\n{uploaded} file(s) uploaded.  Run `fxpak.py menu` to reset into the menu.")
    finally:
        os.close(fd)
    return 0


if __name__ == '__main__':
    sys.exit(main())
