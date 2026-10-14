#!/usr/bin/python3
"""Run OpenWrt lpac against only the secondary Baiwang eUICC serial port.

The modem implements AT+CCHC=<channel> but rejects the optional =? probe.
lpac 2.3.0 treats that probe as mandatory. This PTY bridge answers only that
capability probe; all real APDUs and channel commands pass to the modem.
"""
import glob
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import termios
import time

LPAC = '/usr/lib/lpac'
ID = ('2ca3', '4006')
MAX_OUTPUT = 256 * 1024


def secondary_tty():
    for entry in glob.glob('/sys/class/tty/ttyUSB*'):
        path = os.path.realpath(os.path.join(entry, 'device'))
        interface = os.path.dirname(path)
        usb = os.path.dirname(interface)
        try:
            def read(name):
                with open(name, encoding='ascii') as f:
                    return f.read().strip()
            if (read(os.path.join(interface, 'bInterfaceNumber')) != '02' or
                    (read(os.path.join(usb, 'idVendor')),
                     read(os.path.join(usb, 'idProduct'))) != ID or
                    read(os.path.join(usb, 'manufacturer')).upper() != 'BAIWANG' or
                    os.path.basename(os.path.realpath(os.path.join(interface, 'driver'))) not in ('option', 'qcserial')):
                continue
            name = os.path.join('/dev', os.path.basename(entry))
            if os.path.exists(name):
                return name
        except (OSError, UnicodeError):
            continue
    raise RuntimeError('未找到第二只 DJI 模块的控制串口')


def raw_serial(fd, vmin=0):
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = vmin
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def run(arguments, deadline_seconds=70):
    tty = secondary_tty()
    serial = os.open(tty, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    master, slave = pty.openpty()
    raw_serial(serial)
    raw_serial(slave, vmin=1)
    env = os.environ.copy()
    env.update(LPAC_APDU='at', LPAC_APDU_AT_DEVICE=os.ttyname(slave),
               LPAC_APDU_AT_DEBUG='0', LPAC_HTTP='curl')
    result_file = tempfile.TemporaryFile(mode='w+b', dir='/tmp')
    process = subprocess.Popen([LPAC] + arguments, stdin=subprocess.DEVNULL,
                               stdout=result_file, stderr=subprocess.DEVNULL,
                               env=env, close_fds=True)
    pending = b''
    started = time.monotonic()
    try:
        while process.poll() is None:
            if time.monotonic() - started > deadline_seconds:
                raise RuntimeError('eSIM 操作超时')
            for ready in select.select([master, serial], [], [], 0.2)[0]:
                chunk = os.read(ready, 4096)
                if not chunk:
                    raise RuntimeError('模块串口中断')
                if ready == serial:
                    os.write(master, chunk)
                else:
                    pending += chunk
                    if len(pending) > 8192:
                        raise RuntimeError('串口命令过长')
                    # lpac sends CRLF. A real modem echoes commands, so mirror
                    # just this probe's echo and result without touching SIM.
                    while b'\r' in pending:
                        line, pending = pending.split(b'\r', 1)
                        if line.startswith(b'\n'):
                            line = line[1:]
                        if line == b'AT+CCHC=?':
                            os.write(master, b'\r\nAT+CCHC=?\r\n\r\nOK\r\n')
                        elif line:
                            os.write(serial, line + b'\r')
        result_file.seek(0)
        output = result_file.read(MAX_OUTPUT + 1)
        if len(output) > MAX_OUTPUT:
            raise RuntimeError('eSIM 返回数据过长')
        try:
            result = json.loads(output.decode('utf-8'))
        except (UnicodeError, ValueError):
            raise RuntimeError('eSIM 管理程序返回异常')
        if result.get('payload', {}).get('code') != 0 or process.returncode:
            raise RuntimeError('eSIM 管理程序未完成操作')
        return result['payload'].get('data')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        result_file.close()
        os.close(slave)
        os.close(master)
        os.close(serial)


if __name__ == '__main__':
    try:
        if sys.argv[1:] not in (['chip', 'info'], ['profile', 'list']):
            raise RuntimeError('仅允许只读查询')
        data = run(sys.argv[1:])
        print(json.dumps({'ok': True, 'data': data}, ensure_ascii=False))
    except (OSError, RuntimeError) as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
