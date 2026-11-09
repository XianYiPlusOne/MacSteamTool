"""Run under the game's CrossOver runner in an isolated test prefix.

Tests Windows user-mode trainer primitives against our own child only. No game,
Steam API, key injection, downloaded trainer, or user save is accessed.
"""
import ctypes as c
from ctypes import wintypes as w
import json
import os
import subprocess
import sys


class Target(c.Structure):
    _fields_ = [("guard_before", c.c_uint64), ("value", c.c_uint64), ("guard_after", c.c_uint64)]


MAGIC = 0x43A7D0097F21B861
ORIGINAL = 120
MODIFIED = 987654321


def child():
    target = Target(MAGIC, ORIGINAL, MAGIC)
    print(json.dumps(dict(pid=os.getpid(), address=c.addressof(target))), flush=True)
    for line in sys.stdin:
        if line.strip() == "quit":
            return
        assert target.guard_before == MAGIC and target.guard_after == MAGIC
        print(json.dumps(dict(value=target.value)), flush=True)


def main():
    assert os.name == "nt" and c.sizeof(c.c_void_p) == 8
    k = c.WinDLL("kernel32", use_last_error=True)
    k.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    k.OpenProcess.restype = w.HANDLE
    for name in ["ReadProcessMemory", "WriteProcessMemory"]:
        fn = getattr(k, name)
        fn.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
        fn.restype = w.BOOL
    k.CloseHandle.argtypes = [w.HANDLE]
    k.CloseHandle.restype = w.BOOL
    process = subprocess.Popen([sys.executable, __file__, "--child"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True, bufsize=1)
    handle = None
    address = None
    def observe():
        process.stdin.write("read\n"); process.stdin.flush()
        return json.loads(process.stdout.readline())["value"]
    def write(value):
        data = c.c_uint64(value); size = c.c_size_t()
        if not k.WriteProcessMemory(handle, address + Target.value.offset, c.byref(data), c.sizeof(data), c.byref(size)):
            raise c.WinError(c.get_last_error())
        assert size.value == c.sizeof(data)
    def read():
        data = Target(); size = c.c_size_t()
        if not k.ReadProcessMemory(handle, address, c.byref(data), c.sizeof(data), c.byref(size)):
            raise c.WinError(c.get_last_error())
        assert size.value == c.sizeof(data) and data.guard_before == MAGIC and data.guard_after == MAGIC
        return data.value
    try:
        info = json.loads(process.stdout.readline())
        assert info["pid"] == process.pid and process.poll() is None
        address = info["address"]
        handle = k.OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x1000, False, process.pid)
        if not handle:
            raise c.WinError(c.get_last_error())
        assert read() == ORIGINAL and observe() == ORIGINAL
        try:
            write(MODIFIED)
            assert read() == MODIFIED and observe() == MODIFIED
        finally:
            write(ORIGINAL)
        assert read() == ORIGINAL and observe() == ORIGINAL
        print(json.dumps(dict(ok=True, platform="Windows x64 under CrossOver", openProcess=True,
                              readProcessMemory=True, writeProcessMemory=True, childObservedChange=True,
                              restored=True, externalProcessesModified=0, steamAPICalls=0, keysSent=0)))
    finally:
        if handle:
            k.CloseHandle(handle)
        if process.poll() is None:
            process.stdin.write("quit\n"); process.stdin.flush()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=10)


if __name__ == "__main__":
    child() if sys.argv[1:] == ["--child"] else main()
