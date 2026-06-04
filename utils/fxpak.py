#!/usr/bin/env python3
"""
fxpak.py -- Direct USB CDC control for FX Pak Pro / sd2snes.

Speaks the native USBINT protocol over /dev/cu.usbmodem* without going through
qusb2snes. Implements the full opcode surface of usbinterface.c at the time of
sd2snes firmware 1.11.x:

  File system:
    info                              firmware/device info + current ROM
    ls [path]                         list a directory
    mkdir <path>                      create a directory
    rm <path>                         remove a file or directory
    mv <src> <dst-basename>           rename (destination is in the same dir)
    put <local> <remote>              upload a file (overwrites)
    get <remote> <local>              download a file

  Memory (SNES/MSU/CMD/CONFIG/CFG spaces):
    read  <space> <addr> <length> [<outfile>]   read raw bytes
    write <space> <addr> <local-file>           write raw bytes (PUT to space)
    vread  <space> <addr1>:<len1> [<addr2>:<len2> ...]  vectored read (max 8)

  Control:
    reset                             reset SNES side
    menu                              reset back to menu
    boot <path>                       boot a ROM
    power-cycle                       hard power cycle
    time <YYYY-MM-DD HH:MM:SS>        set RTC

  Convenience:
    install-parmk3 [--bundle DIR]     upload the PAR MK3 release bundle

Protocol summary (from src/usbinterface.c):
  Cmd frame (512 bytes):
    [0..3]    'USBA'
    [4]       opcode
    [5]       space
    [6]       flags
    [252..255] U32BE size (PUT total, GET length)
    [256..]   filename C-string (SP_FILE) or U32BE offset (other spaces)
    [8..]     MV new basename (when opcode=MV)
    [4+4..]   TIME fields
    [32+i*4]  VGET/VPUT vector i: 1 byte size + 3 byte addr (BE), 8 entries
  Response (512 bytes, unless F_NORESP):
    [0..3]    'USBA'
    [4]       0x0f
    [5]       error code
    [252..255] U32BE total size of subsequent data stream
    INFO only:
       [6..9]   feature flags (U32LE)
       [10..11] cfg switches (U16LE)
       [16..]   current ROM filename
       [256..259] FWVER magic (U32BE)
       [260..323] firmware version string
       [324..387] device name
  Data stream (GET/VGET/LS): 512-byte blocks following the response.

LS data-block layout: entries are [type:1][name\0]... where type 0=dir,
1=file, 2=continuation (more blocks follow), 0xFF=end-of-list.

No external Python deps; only os/struct/argparse/glob from the stdlib.
"""

from __future__ import annotations

import argparse
import glob
import os
import struct
import sys
import time
from typing import Iterable, List, Optional, Tuple


# ---- Protocol constants ----------------------------------------------------

OP_GET, OP_PUT, OP_VGET, OP_VPUT = 0, 1, 2, 3
OP_LS, OP_MKDIR, OP_RM, OP_MV    = 4, 5, 6, 7
OP_RESET, OP_BOOT, OP_POWER_CYCLE, OP_INFO = 8, 9, 10, 11
OP_MENU_RESET = 12
OP_STREAM     = 13
OP_TIME       = 14
OP_RESPONSE   = 0x0f

SP_FILE, SP_SNES, SP_MSU, SP_CMD, SP_CONFIG, SP_CFG = range(6)

SPACE_BY_NAME = {
    'file':   SP_FILE,
    'snes':   SP_SNES,
    'msu':    SP_MSU,
    'cmd':    SP_CMD,
    'config': SP_CONFIG,
    'cfg':    SP_CFG,
}

F_NONE        = 0x00
F_SKIPRESET   = 0x01
F_ONLYRESET   = 0x02
F_NORESP      = 0x40
F_64BDATA     = 0x80
F_STREAMBURST = 0x100  # not all firmwares accept this

# LS data-block markers
LS_DIR  = 0x00
LS_FILE = 0x01
LS_CONT = 0x02
LS_END  = 0xFF

BLOCK = 512
RESP_TIMEOUT = 4.0   # seconds


# ---- Transport -------------------------------------------------------------

def open_dev(path: str) -> int:
    return os.open(path, os.O_RDWR | os.O_NOCTTY)


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
    raw_overrides: Optional[List[Tuple[int, bytes]]] = None,
) -> bytes:
    """Build a 512-byte command frame.

    raw_overrides is a list of (offset, bytes) tuples written after the
    default fields -- used by MV (basename at offset 8), TIME, VGET/VPUT.
    """
    cmd = bytearray(BLOCK)
    cmd[0:4] = b'USBA'
    cmd[4] = opcode
    cmd[5] = space
    cmd[6] = flags
    struct.pack_into('>I', cmd, 252, size & 0xFFFFFFFF)
    if filename is not None:
        fn = filename.encode('ascii', errors='replace')
        if len(fn) > BLOCK - 256 - 1:
            raise ValueError(f"filename too long: {filename!r}")
        cmd[256:256 + len(fn)] = fn
    elif space != SP_FILE:
        struct.pack_into('>I', cmd, 256, address & 0xFFFFFFFF)
    if raw_overrides:
        for off, blob in raw_overrides:
            cmd[off:off + len(blob)] = blob
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


def resp_error(resp: bytes) -> int:
    return resp[5]


def resp_size(resp: bytes) -> int:
    return struct.unpack_from('>I', resp, 252)[0]


# ---- Opcode wrappers -------------------------------------------------------

def cmd_info(fd: int) -> dict:
    send_cmd(fd, opcode=OP_INFO, space=SP_SNES, flags=F_NONE)
    resp = recv_response(fd)
    return {
        'feature_flags': struct.unpack_from('<I', resp, 6)[0],
        'cfg_switches':  struct.unpack_from('<H', resp, 10)[0],
        'rom_name':      resp[16:256].split(b'\x00', 1)[0].decode('ascii', 'replace'),
        'fwver_magic':   struct.unpack_from('>I', resp, 256)[0],
        'fwver_string':  resp[260:324].split(b'\x00', 1)[0].decode('ascii', 'replace'),
        'device_name':   resp[324:388].split(b'\x00', 1)[0].decode('ascii', 'replace'),
    }


def cmd_reset(fd: int) -> None:
    send_cmd(fd, opcode=OP_RESET, space=SP_SNES, flags=F_NORESP)


def cmd_menu(fd: int) -> None:
    send_cmd(fd, opcode=OP_MENU_RESET, space=SP_SNES, flags=F_NORESP)


def cmd_power_cycle(fd: int) -> None:
    send_cmd(fd, opcode=OP_POWER_CYCLE, space=SP_SNES, flags=F_NORESP)


def cmd_boot(fd: int, remote_path: str) -> None:
    send_cmd(fd, opcode=OP_BOOT, space=SP_FILE, flags=F_NORESP, filename=remote_path)


def cmd_mkdir(fd: int, remote_path: str) -> None:
    send_cmd(fd, opcode=OP_MKDIR, space=SP_FILE, flags=F_NONE, filename=remote_path)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"MKDIR {remote_path} failed, error=0x{resp_error(resp):02x}")


def cmd_rm(fd: int, remote_path: str) -> None:
    send_cmd(fd, opcode=OP_RM, space=SP_FILE, flags=F_NONE, filename=remote_path)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"RM {remote_path} failed, error=0x{resp_error(resp):02x}")


def cmd_mv(fd: int, src: str, new_basename: str) -> None:
    """Rename src to new_basename within the same directory.

    The firmware MV handler strips the basename from src, then appends
    cmd_buffer[8:] as the new basename. So we put the new basename at
    offset 8, not at the filename area.
    """
    if '/' in new_basename or '\\' in new_basename:
        raise ValueError("MV destination must be a basename only (no slashes)")
    new_b = new_basename.encode('ascii', errors='replace') + b'\x00'
    send_cmd(fd, opcode=OP_MV, space=SP_FILE, flags=F_NONE, filename=src,
             raw_overrides=[(8, new_b)])
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"MV {src} -> {new_basename} failed, error=0x{resp_error(resp):02x}")


def cmd_put(fd: int, local_path: str, remote_path: str) -> int:
    with open(local_path, 'rb') as f:
        data = f.read()
    size = len(data)
    # NOTE: we use the standard (non-NORESP) response handshake so the
    # firmware tells us when the file open succeeded before we stream
    # data. There is a race on the firmware side between sending the
    # response and enabling the USB IRQ for data ingress; a short pause
    # avoids losing the first OUT packets. Same for the trailing pause
    # so a follow-up command does not arrive while SD flushing is still
    # in progress.
    send_cmd(fd, opcode=OP_PUT, space=SP_FILE, flags=F_NONE,
             filename=remote_path, size=size)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"PUT {remote_path} init failed, error=0x{resp_error(resp):02x}")
    time.sleep(0.2)
    sent = 0
    while sent < size:
        chunk = data[sent:sent + BLOCK]
        if len(chunk) < BLOCK:
            chunk = chunk + b'\x00' * (BLOCK - len(chunk))
        write_all(fd, chunk)
        sent += BLOCK
    # Let the SD write + lock release finish before the caller fires the
    # next command. 200 ms per file is a tiny cost for small files; for
    # multi-megabyte uploads the actual write takes longer than the wait.
    time.sleep(0.3)
    return size


def cmd_get(fd: int, remote_path: str, local_path: str) -> int:
    send_cmd(fd, opcode=OP_GET, space=SP_FILE, flags=F_NONE, filename=remote_path)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"GET {remote_path} failed, error=0x{resp_error(resp):02x}")
    size = resp_size(resp)
    blocks = (size + BLOCK - 1) // BLOCK
    buf = bytearray()
    for _ in range(blocks):
        buf += read_exact(fd, BLOCK)
    buf = bytes(buf[:size])
    with open(local_path, 'wb') as f:
        f.write(buf)
    return size


def cmd_read(fd: int, space: int, addr: int, length: int) -> bytes:
    """GET <length> bytes from a non-file memory space starting at addr."""
    send_cmd(fd, opcode=OP_GET, space=space, flags=F_NONE,
             address=addr, size=length)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"GET space={space} addr=0x{addr:x} failed, error=0x{resp_error(resp):02x}")
    # firmware respects size set in cmd_buffer[252..255] (mirrored back in resp[252..255])
    size = resp_size(resp) or length
    blocks = (size + BLOCK - 1) // BLOCK
    buf = bytearray()
    for _ in range(blocks):
        buf += read_exact(fd, BLOCK)
    return bytes(buf[:size])


def cmd_write(fd: int, space: int, addr: int, data: bytes) -> int:
    """PUT raw bytes into a non-file memory space."""
    size = len(data)
    send_cmd(fd, opcode=OP_PUT, space=space, flags=F_NONE,
             address=addr, size=size)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"PUT space={space} addr=0x{addr:x} failed, error=0x{resp_error(resp):02x}")
    time.sleep(0.2)
    sent = 0
    while sent < size:
        chunk = data[sent:sent + BLOCK]
        if len(chunk) < BLOCK:
            chunk = chunk + b'\x00' * (BLOCK - len(chunk))
        write_all(fd, chunk)
        sent += BLOCK
    time.sleep(0.2)
    return size


def cmd_vread(fd: int, space: int, ranges: List[Tuple[int, int]]) -> List[bytes]:
    """Vectored read: up to 8 (addr, len) ranges in a single command.

    Each entry takes 4 bytes at cmd[32 + i*4]: [size:1][addr_hi:1][addr_mid:1][addr_lo:1].
    The firmware uses 64-byte data blocks for V-ops (cmd_size also 64).
    Total size is the sum of all len values; the response data stream is a
    concatenation of all ranges in order.
    """
    if len(ranges) > 8:
        raise ValueError("VGET supports at most 8 ranges per command")
    overrides = []
    total = 0
    for i, (addr, size) in enumerate(ranges):
        if size > 255:
            raise ValueError("each VGET range size must fit in 1 byte (<=255)")
        if addr >= (1 << 24):
            raise ValueError("VGET address must fit in 24 bits")
        total += size
        blob = bytes([size, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF])
        overrides.append((32 + i * 4, blob))
    # Zero-pad the rest of the vector slots
    for i in range(len(ranges), 8):
        overrides.append((32 + i * 4, b'\x00\x00\x00\x00'))
    send_cmd(fd, opcode=OP_VGET, space=space, flags=F_64BDATA,
             raw_overrides=overrides)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"VGET space={space} failed, error=0x{resp_error(resp):02x}")
    # V-ops use 64-byte blocks
    block = 64
    blocks = (total + block - 1) // block
    buf = bytearray()
    for _ in range(blocks):
        buf += read_exact(fd, block)
    buf = bytes(buf[:total])
    out = []
    off = 0
    for _, size in ranges:
        out.append(buf[off:off + size])
        off += size
    return out


def cmd_time(fd: int, tm: time.struct_time) -> None:
    blob = bytes([
        tm.tm_sec & 0xFF,
        tm.tm_min & 0xFF,
        tm.tm_hour & 0xFF,
        tm.tm_mday & 0xFF,
        tm.tm_mon & 0xFF,
        (tm.tm_year >> 8) & 0xFF,
        tm.tm_year & 0xFF,
        tm.tm_wday & 0xFF,
    ])
    # Fields start at cmd_buffer[4+4] = offset 8.
    send_cmd(fd, opcode=OP_TIME, space=SP_SNES, flags=F_NONE,
             raw_overrides=[(8, blob)])
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"TIME failed, error=0x{resp_error(resp):02x}")


def cmd_ls(fd: int, remote_dir: str) -> List[Tuple[str, str]]:
    """List a directory. Returns list of (kind, name) where kind is 'dir' or 'file'."""
    send_cmd(fd, opcode=OP_LS, space=SP_FILE, flags=F_NONE, filename=remote_dir)
    resp = recv_response(fd)
    if resp_error(resp):
        raise IOError(f"LS {remote_dir} failed, error=0x{resp_error(resp):02x}")

    entries: List[Tuple[str, str]] = []
    done = False
    while not done:
        blk = read_exact(fd, BLOCK)
        i = 0
        while i < BLOCK:
            t = blk[i]
            i += 1
            if t == LS_END:
                done = True
                break
            if t == LS_CONT:
                # block was full; firmware sent a continuation marker --
                # break out and read the next data block from the start.
                break
            if t not in (LS_DIR, LS_FILE):
                # block padding -- everything after this is zero filler
                done = True
                break
            end = blk.find(b'\x00', i)
            if end < 0:
                # Malformed -- treat as end so we don't loop forever.
                done = True
                break
            name = blk[i:end].decode('ascii', 'replace')
            i = end + 1
            entries.append(('dir' if t == LS_DIR else 'file', name))
    return entries


# ---- Device auto-detect ----------------------------------------------------

def autodetect_dev() -> Optional[str]:
    """Pick the first /dev/cu.usbmodem* that looks like an sd2snes / FX Pak."""
    candidates = sorted(glob.glob('/dev/cu.usbmodem*'))
    return candidates[0] if candidates else None


DEFAULT_DEV = autodetect_dev() or '/dev/cu.usbmodem'


# ---- CLI -------------------------------------------------------------------

def _parse_space(name: str) -> int:
    if name.lower() not in SPACE_BY_NAME:
        raise argparse.ArgumentTypeError(f"unknown space {name!r}, expected one of: {', '.join(SPACE_BY_NAME)}")
    return SPACE_BY_NAME[name.lower()]


def _parse_int(s: str) -> int:
    return int(s, 0)  # accepts 0x..., 0..., decimal


def _parse_range(s: str) -> Tuple[int, int]:
    addr_s, _, len_s = s.partition(':')
    if not len_s:
        raise argparse.ArgumentTypeError(f"range must be addr:len, got {s!r}")
    return (_parse_int(addr_s), _parse_int(len_s))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split('\n\n', 1)[0])
    p.add_argument('--dev', default=DEFAULT_DEV, help=f'serial device (default: {DEFAULT_DEV})')
    sub = p.add_subparsers(dest='cmd', required=True)

    sub.add_parser('info')
    sub.add_parser('reset')
    sub.add_parser('menu')
    sub.add_parser('power-cycle')

    p_boot = sub.add_parser('boot')
    p_boot.add_argument('remote', help='ROM path on the card, e.g. /myrom.smc')

    p_ls = sub.add_parser('ls')
    p_ls.add_argument('remote', nargs='?', default='/')

    p_mkdir = sub.add_parser('mkdir')
    p_mkdir.add_argument('remote')

    p_rm = sub.add_parser('rm')
    p_rm.add_argument('remote')

    p_mv = sub.add_parser('mv')
    p_mv.add_argument('src')
    p_mv.add_argument('new_basename')

    p_put = sub.add_parser('put')
    p_put.add_argument('local')
    p_put.add_argument('remote')

    p_get = sub.add_parser('get')
    p_get.add_argument('remote')
    p_get.add_argument('local')

    p_read = sub.add_parser('read', help='raw read from a memory space')
    p_read.add_argument('space', type=_parse_space)
    p_read.add_argument('addr', type=_parse_int)
    p_read.add_argument('length', type=_parse_int)
    p_read.add_argument('outfile', nargs='?', help='if omitted: hex dump to stdout')

    p_write = sub.add_parser('write', help='raw write to a memory space')
    p_write.add_argument('space', type=_parse_space)
    p_write.add_argument('addr', type=_parse_int)
    p_write.add_argument('local', help='file containing bytes to upload')

    p_vread = sub.add_parser('vread', help='vectored read (up to 8 addr:len ranges)')
    p_vread.add_argument('space', type=_parse_space)
    p_vread.add_argument('ranges', nargs='+', type=_parse_range,
                         help='one or more ADDR:LEN pairs, max 8, LEN<=255')

    p_time = sub.add_parser('time', help='set RTC')
    p_time.add_argument('iso', nargs='?',
                        help='ISO-like "YYYY-MM-DD HH:MM:SS"; default = host time now')

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
            print(f"Features:  0x{info['feature_flags']:08x}")
            print(f"Cfg:       0x{info['cfg_switches']:04x}")
        elif args.cmd == 'reset':
            cmd_reset(fd); print("reset sent")
        elif args.cmd == 'menu':
            cmd_menu(fd); print("menu reset sent")
        elif args.cmd == 'power-cycle':
            cmd_power_cycle(fd); print("power cycle sent")
        elif args.cmd == 'boot':
            cmd_boot(fd, args.remote); print(f"boot {args.remote} sent")
        elif args.cmd == 'ls':
            for kind, name in cmd_ls(fd, args.remote):
                print(f"{kind:4} {name}")
        elif args.cmd == 'mkdir':
            cmd_mkdir(fd, args.remote); print(f"mkdir {args.remote} ok")
        elif args.cmd == 'rm':
            cmd_rm(fd, args.remote); print(f"rm {args.remote} ok")
        elif args.cmd == 'mv':
            cmd_mv(fd, args.src, args.new_basename); print(f"mv {args.src} -> {args.new_basename} ok")
        elif args.cmd == 'put':
            n = cmd_put(fd, args.local, args.remote)
            print(f"put {args.local} -> {args.remote}  ({n} bytes)")
        elif args.cmd == 'get':
            n = cmd_get(fd, args.remote, args.local)
            print(f"get {args.remote} -> {args.local}  ({n} bytes)")
        elif args.cmd == 'read':
            data = cmd_read(fd, args.space, args.addr, args.length)
            if args.outfile:
                with open(args.outfile, 'wb') as f:
                    f.write(data)
                print(f"read {args.length} bytes -> {args.outfile}")
            else:
                for off in range(0, len(data), 16):
                    chunk = data[off:off + 16]
                    print(f"{args.addr + off:06x}  " + ' '.join(f"{b:02x}" for b in chunk))
        elif args.cmd == 'write':
            with open(args.local, 'rb') as f:
                payload = f.read()
            n = cmd_write(fd, args.space, args.addr, payload)
            print(f"write {n} bytes -> space={args.space} addr=0x{args.addr:x}")
        elif args.cmd == 'vread':
            results = cmd_vread(fd, args.space, args.ranges)
            for (addr, size), chunk in zip(args.ranges, results):
                print(f"  {addr:06x} {size:3} {' '.join(f'{b:02x}' for b in chunk)}")
        elif args.cmd == 'time':
            if args.iso:
                tm = time.strptime(args.iso, '%Y-%m-%d %H:%M:%S')
            else:
                tm = time.localtime()
            cmd_time(fd, tm); print(f"rtc set to {time.strftime('%Y-%m-%d %H:%M:%S', tm)}")
        elif args.cmd == 'install-parmk3':
            bundle = args.bundle
            wanted = [
                ('fpga_parmk3.bi3', '/sd2snes/fpga_parmk3.bi3'),
                ('fpga_parmk3.bit', '/sd2snes/fpga_parmk3.bit'),
                ('m3nu.bin',        '/sd2snes/m3nu.bin'),
                ('menu.bin',        '/sd2snes/menu.bin'),
                ('firmware.im3',    '/sd2snes/firmware.im3'),
                ('firmware.stm',    '/sd2snes/firmware.stm'),
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
