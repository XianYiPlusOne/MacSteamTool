"""Read-only initialization using an installed game's own steam_api64.dll.

Run with Windows Python through the private NotProton test prefix, supplying
DLL path and JSON output path. The currently authorized test app is 4348910.
No SetAchievement, StoreStats, game executable, or save-file writes.
"""
import ctypes as c
import json
import os
import sys
import time

APP = 4348910
os.environ["SteamAppId"] = str(APP)
os.environ["SteamGameId"] = str(APP)
api = c.CDLL(sys.argv[1])


def fn(name, result, *args):
    value = getattr(api, name); value.restype = result; value.argtypes = list(args)
    return value


class Callback(c.Structure):
    _fields_ = [("user", c.c_int), ("id", c.c_int), ("data", c.c_void_p), ("size", c.c_int)]


error = c.create_string_buffer(1024)
assert fn("SteamAPI_InitFlat", c.c_int, c.c_char_p)(error) == 0, ("Game SteamAPI_InitFlat failed", error.value.decode(errors="replace"))
try:
    fn("SteamAPI_ManualDispatch_Init", None)()
    pipe = fn("SteamAPI_GetHSteamPipe", c.c_int)()
    stats = fn("SteamAPI_SteamUserStats_v013", c.c_void_p)()
    user = fn("SteamAPI_SteamUser_v023", c.c_void_p)()
    utils = fn("SteamAPI_SteamUtils_v010", c.c_void_p)()
    assert pipe and stats and user and utils
    assert fn("SteamAPI_ISteamUtils_GetAppID", c.c_uint32, c.c_void_p)(utils) == APP
    sid = fn("SteamAPI_ISteamUser_GetSteamID", c.c_uint64, c.c_void_p)(user)
    assert fn("SteamAPI_ISteamUserStats_RequestUserStats", c.c_uint64, c.c_void_p, c.c_uint64)(stats, sid)
    run = fn("SteamAPI_ManualDispatch_RunFrame", None, c.c_int)
    get = fn("SteamAPI_ManualDispatch_GetNextCallback", c.c_bool, c.c_int, c.POINTER(Callback))
    free = fn("SteamAPI_ManualDispatch_FreeLastCallback", None, c.c_int)
    result = None; until = time.monotonic() + 30
    while result is None and time.monotonic() < until:
        run(pipe); message = Callback()
        while get(pipe, c.byref(message)):
            if message.id == 1101 and message.size in (20, 24):
                data = c.string_at(message.data, message.size)
                if int.from_bytes(data[:8], "little") == APP and int.from_bytes(data[-8:], "little") == sid:
                    result = int.from_bytes(data[8:12], "little")
            free(pipe)
        time.sleep(.02)
    assert result == 1, ("Game UserStatsReceived callback", result)
    count = fn("SteamAPI_ISteamUserStats_GetNumAchievements", c.c_uint32, c.c_void_p)(stats)
    name = fn("SteamAPI_ISteamUserStats_GetAchievementName", c.c_char_p, c.c_void_p, c.c_uint32)
    read = fn("SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime", c.c_bool, c.c_void_p, c.c_char_p, c.POINTER(c.c_bool), c.POINTER(c.c_uint32))
    assert 0 < count < 10000
    rows = []
    for i in range(count):
        key = name(stats, i); achieved = c.c_bool(); timestamp = c.c_uint32()
        assert key and read(stats, key, c.byref(achieved), c.byref(timestamp))
        rows.append(dict(id=key.decode(), achieved=achieved.value, unlockedAt=timestamp.value))
    with open(sys.argv[2], "w") as stream:
        json.dump(dict(ok=True, appID=APP, callbackResult=result, achievements=rows, writes=False), stream)
    print(f"PASS: installed game steam_api64.dll -> NotProton -> native Steam; init, same-user callback EResult=1, {count} achievement states; read-only.")
finally:
    fn("SteamAPI_Shutdown", None)()
