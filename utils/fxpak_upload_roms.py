#!/usr/bin/env python3
"""Upload all roms/*.sfc to the FX Pak /roms/ with a live progress log.

Writes per-block progress to a log file (flushed every line) so a watcher
can tail it without ever interrupting the transfer. Designed to run to
completion unattended -- killing it mid-transfer wedges the cart's USB
state machine, so don't.

Usage: fxpak_upload_roms.py <progress-log-path>
"""
import sys, os, time, glob, struct, termios
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
import fxpak

BLOCK = 512
THROTTLE = 32 * 1024   # pause every 32 KB

def log(fh, msg):
    fh.write(msg + "\n")
    fh.flush()
    os.fsync(fh.fileno())

def put_with_progress(fd, local, remote, fh):
    with open(local, 'rb') as f:
        data = f.read()
    size = len(data)
    fxpak.send_cmd(fd, opcode=fxpak.OP_PUT, space=fxpak.SP_FILE,
                   flags=fxpak.F_NONE, filename=remote, size=size)
    resp = fxpak.recv_response(fd)
    if fxpak.resp_error(resp):
        raise IOError(f"PUT init failed err=0x{fxpak.resp_error(resp):02x}")
    time.sleep(0.2)
    sent = 0
    since = 0
    last_pct = -1
    while sent < size:
        chunk = data[sent:sent+BLOCK]
        if len(chunk) < BLOCK:
            chunk = chunk + b'\x00' * (BLOCK - len(chunk))
        fxpak.write_all(fd, chunk)
        sent += BLOCK
        since += BLOCK
        if since >= THROTTLE:
            since = 0
            time.sleep(0.004)
            pct = min(100, sent * 100 // size)
            if pct != last_pct:
                last_pct = pct
                log(fh, f"  {os.path.basename(local)}: {pct}% ({min(sent,size)}/{size})")
    time.sleep(0.3)
    return size

def main():
    logpath = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fxpak-upload.log"
    fh = open(logpath, "w")
    roms = sorted(glob.glob(os.path.join(os.path.dirname(__file__), "..", "roms", "*.sfc")))
    log(fh, f"START {len(roms)} roms")
    fd = fxpak.open_dev(fxpak.DEFAULT_DEV)
    termios.tcflush(fd, termios.TCIOFLUSH)
    # make sure /roms exists
    try:
        fxpak.cmd_mkdir(fd, "/roms")
    except Exception:
        pass  # already exists
    try:
        for f in roms:
            base = os.path.basename(f)
            log(fh, f"BEGIN {base}")
            t0 = time.time()
            n = put_with_progress(fd, f, "/roms/" + base, fh)
            log(fh, f"DONE  {base}  {n} bytes in {time.time()-t0:.1f}s")
    except Exception as e:
        log(fh, f"ERROR {e}")
        fxpak.os.close(fd)
        fh.close()
        sys.exit(1)
    fxpak.os.close(fd)
    log(fh, "ALL DONE")
    fh.close()

if __name__ == "__main__":
    main()
