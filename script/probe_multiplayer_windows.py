"""Windows-side live Steam multiplayer diagnostics, invoked by the host runner.

Only AppID 480 is used. Creates a private, one-member test lobby, closes joining,
and sends binary data only after verifying that the current user is its sole
member. No friends, invitations, achievements, tickets, or game saves are used.
Socket tests use real UDP loopback, not an Internet peer or a second player.
"""
import ctypes as c
import hashlib
import json
import os
import sys
import time
import uuid
from pathlib import Path

os.environ['SteamAppId'] = os.environ['SteamGameId'] = '480'
api = c.CDLL(sys.argv[1])
output = Path(sys.argv[2])
sys.stdout = sys.stderr = output.with_suffix('.worker.log').open('w', buffering=1, encoding='utf-8')
report = {'appID': 480, 'checks': [], 'twoPlayerTest': False}


def fn(name, result, *args):
    value = getattr(api, name)
    value.restype = result
    value.argtypes = list(args)
    return value


def record(name, **details):
    report['checks'].append({'name': name, 'ok': True, **details})
    output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('PASS:', name, json.dumps(details), flush=True)


class Callback(c.Structure):
    _fields_ = [('user', c.c_int), ('id', c.c_int), ('data', c.c_void_p), ('size', c.c_int)]


class LobbyCreated(c.Structure):
    _fields_ = [('result', c.c_int), ('lobby', c.c_uint64)]


class MessageHeader(c.Structure):
    # Read only the documented prefix; release through the SDK export.
    _fields_ = [('data', c.c_void_p), ('size', c.c_int), ('connection', c.c_uint32)]


initialized = False
lobby = 0
connections = []
sockets = None
events = []
chat = []
try:
    error = c.create_string_buffer(1024)
    versions = b'SteamUtils010\0SteamUser023\0SteamMatchMaking009\0SteamNetworkingSockets012\0SteamNetworkingUtils004\0\0'
    status = fn('SteamInternal_SteamAPI_Init', c.c_int, c.c_char_p, c.c_char_p)(versions, error)
    assert status == 0, ('Steam API initialization', status, error.value.decode(errors='replace'))
    initialized = True
    fn('SteamAPI_ManualDispatch_Init', None)()
    pipe = fn('SteamAPI_GetHSteamPipe', c.c_int)()
    user_handle = fn('SteamAPI_GetHSteamUser', c.c_int)()
    utils = fn('SteamAPI_SteamUtils_v010', c.c_void_p)()
    user = fn('SteamAPI_SteamUser_v023', c.c_void_p)()
    mm = fn('SteamAPI_SteamMatchmaking_v009', c.c_void_p)()
    assert all([pipe, user_handle, utils, user, mm]), 'Missing Steam interface'
    assert fn('SteamAPI_ISteamUtils_GetAppID', c.c_uint32, c.c_void_p)(utils) == 480
    assert fn('SteamAPI_ISteamUser_BLoggedOn', c.c_bool, c.c_void_p)(user), 'Steam is offline'
    sid = fn('SteamAPI_ISteamUser_GetSteamID', c.c_uint64, c.c_void_p)(user)
    assert sid
    record('logged_in_native_steam_via_windows_sdk', sdkSHA256=hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())

    run = fn('SteamAPI_ManualDispatch_RunFrame', None, c.c_int)
    get = fn('SteamAPI_ManualDispatch_GetNextCallback', c.c_bool, c.c_int, c.POINTER(Callback))
    free = fn('SteamAPI_ManualDispatch_FreeLastCallback', None, c.c_int)
    members = fn('SteamAPI_ISteamMatchmaking_GetNumLobbyMembers', c.c_int, c.c_void_p, c.c_uint64)
    owner = fn('SteamAPI_ISteamMatchmaking_GetLobbyOwner', c.c_uint64, c.c_void_p, c.c_uint64)
    read_chat = fn('SteamAPI_ISteamMatchmaking_GetLobbyChatEntry', c.c_int, c.c_void_p, c.c_uint64, c.c_int, c.POINTER(c.c_uint64), c.c_void_p, c.c_int, c.POINTER(c.c_int))

    def pump():
        run(pipe)
        message = Callback()
        while get(pipe, c.byref(message)):
            try:
                if message.user != user_handle or not message.data or not 0 < message.size < 4096:
                    continue
                raw = c.string_at(message.data, message.size)
                events.append((message.id, raw))
                # Chat entry indexes are valid only while the callback is alive.
                if message.id == 507 and len(raw) == 24 and int.from_bytes(raw[:8], 'little') == lobby:
                    entry = int.from_bytes(raw[20:24], 'little')
                    sender, kind = c.c_uint64(), c.c_int()
                    buffer = c.create_string_buffer(4096)
                    size = read_chat(mm, lobby, entry, c.byref(sender), buffer, len(buffer), c.byref(kind))
                    assert 0 <= size <= len(buffer)
                    chat.append((sender.value, buffer.raw[:size]))
            finally:
                free(pipe)

    def wait_until(predicate, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pump()
            if predicate():
                return
            time.sleep(.02)
        raise AssertionError('Timed out waiting for Steam response')

    def call_result(call, kind, struct):
        assert call, 'Steam rejected asynchronous request'
        failed = c.c_bool()
        complete = fn('SteamAPI_ISteamUtils_IsAPICallCompleted', c.c_bool, c.c_void_p, c.c_uint64, c.POINTER(c.c_bool))
        wait_until(lambda: complete(utils, call, c.byref(failed)))
        assert not failed.value, ('Steam asynchronous I/O failure', kind)
        result = struct()
        ok = fn('SteamAPI_ISteamUtils_GetAPICallResult', c.c_bool, c.c_void_p, c.c_uint64, c.c_void_p, c.c_int, c.c_int, c.POINTER(c.c_bool))(utils, call, c.byref(result), c.sizeof(result), kind, c.byref(failed))
        assert ok and not failed.value, ('Invalid Steam call result', kind)
        return result

    create = fn('SteamAPI_ISteamMatchmaking_CreateLobby', c.c_uint64, c.c_void_p, c.c_int, c.c_int)
    created = call_result(create(mm, 0, 1), 513, LobbyCreated)
    # Remember the lobby before assertions so failure still triggers cleanup.
    lobby = created.lobby
    assert created.result == 1 and lobby, ('LobbyCreated', created.result)
    assert fn('SteamAPI_ISteamMatchmaking_SetLobbyJoinable', c.c_bool, c.c_void_p, c.c_uint64, c.c_bool)(mm, lobby, False)
    assert members(mm, lobby) == 1 and owner(mm, lobby) == sid
    record('private_lobby_server_created', result=created.result, members=1, joinable=False)

    nonce = uuid.uuid4().hex.encode()
    set_data = fn('SteamAPI_ISteamMatchmaking_SetLobbyData', c.c_bool, c.c_void_p, c.c_uint64, c.c_char_p, c.c_char_p)
    get_data = fn('SteamAPI_ISteamMatchmaking_GetLobbyData', c.c_char_p, c.c_void_p, c.c_uint64, c.c_char_p)
    events.clear()
    assert set_data(mm, lobby, b'fluent_probe_nonce', nonce)
    wait_until(lambda: any(i == 505 and len(v) >= 17 and int.from_bytes(v[:8], 'little') == lobby and v[16] == 1 for i, v in events))
    assert get_data(mm, lobby, b'fluent_probe_nonce') == nonce
    record('lobby_metadata_callback_and_exact_readback')

    # Request only a unique nonce, never enumerate or join other players' rooms.
    fn('SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter', None, c.c_void_p, c.c_char_p, c.c_char_p, c.c_int)(mm, b'fluent_probe_nonce', nonce, 0)
    fn('SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter', None, c.c_void_p, c.c_int)(mm, 3)
    found = call_result(fn('SteamAPI_ISteamMatchmaking_RequestLobbyList', c.c_uint64, c.c_void_p)(mm), 510, c.c_uint32)
    assert found.value == 0, 'Private, closed lobby unexpectedly publicly discoverable'
    record('filtered_lobby_query_server_response', count=0, expected='private closed lobby excluded')

    send_chat = fn('SteamAPI_ISteamMatchmaking_SendLobbyChatMsg', c.c_bool, c.c_void_p, c.c_uint64, c.c_void_p, c.c_int)
    for size in [64, 1024, 4096]:
        payload = (b'FLUENT_PROBE\0' + os.urandom(size))[:size]
        assert members(mm, lobby) == 1 and owner(mm, lobby) == sid
        assert send_chat(mm, lobby, payload, len(payload)), 'Lobby data send refused'
        wait_until(lambda: (sid, payload) in chat)
    record('lobby_binary_roundtrip_via_steam_backend', payloadBytes=[64, 1024, 4096], recipients=1)

    sockets = fn('SteamAPI_SteamNetworkingSockets_SteamAPI_v012', c.c_void_p)()
    assert sockets, 'SteamNetworkingSockets012 unavailable'
    pair = fn('SteamAPI_ISteamNetworkingSockets_CreateSocketPair', c.c_bool, c.c_void_p, c.POINTER(c.c_uint32), c.POINTER(c.c_uint32), c.c_bool, c.c_void_p, c.c_void_p)
    left, right = c.c_uint32(), c.c_uint32()
    assert pair(sockets, c.byref(left), c.byref(right), True, None, None), 'UDP loopback pair creation failed'
    connections = [left.value, right.value]
    send = fn('SteamAPI_ISteamNetworkingSockets_SendMessageToConnection', c.c_int, c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32, c.c_int, c.POINTER(c.c_int64))
    receive = fn('SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection', c.c_int, c.c_void_p, c.c_uint32, c.POINTER(c.c_void_p), c.c_int)
    release = fn('SteamAPI_SteamNetworkingMessage_t_Release', None, c.c_void_p)
    total = 0
    for index in range(16):
        for source, dest in [(left.value, right.value), (right.value, left.value)]:
            size = [1, 32, 512, 4096, 65536][index % 5]
            payload = os.urandom(size)
            number = c.c_int64()
            assert send(sockets, source, payload, size, 9, c.byref(number)) == 1
            received = []

            def take_message():
                ptr = c.c_void_p()
                count = receive(sockets, dest, c.byref(ptr), 1)
                assert count >= 0, 'UDP connection became invalid'
                if not count:
                    return False
                try:
                    value = c.cast(ptr, c.POINTER(MessageHeader)).contents
                    assert value.connection == dest and 0 <= value.size <= 65536
                    received.append(c.string_at(value.data, value.size))
                finally:
                    release(ptr)
                return True

            wait_until(take_message)
            assert received == [payload], 'UDP payload mismatch'
            total += size
    record('steam_networking_real_udp_loopback', messages=32, bytes=total, bidirectional=True, exactPayloadMatch=True, internetPeer=False)
    close = fn('SteamAPI_ISteamNetworkingSockets_CloseConnection', c.c_bool, c.c_void_p, c.c_uint32, c.c_int, c.c_char_p, c.c_bool)
    for connection in connections:
        assert close(sockets, connection, 1000, b'Fluent probe complete', False)
    connections.clear()
    status = send(sockets, left.value, b'x', 1, 9, None)
    assert status != 1
    record('closed_socket_rejects_send', result=status)
    report['ok'] = True
except Exception as error:
    report['ok'] = False
    report['error'] = str(error)
    print('FAIL:', str(error), flush=True)
finally:
    if sockets:
        for connection in connections:
            fn('SteamAPI_ISteamNetworkingSockets_CloseConnection', c.c_bool, c.c_void_p, c.c_uint32, c.c_int, c.c_char_p, c.c_bool)(sockets, connection, 1000, b'Fluent probe cleanup', False)
    if lobby:
        events.clear()
        fn('SteamAPI_ISteamMatchmaking_LeaveLobby', None, c.c_void_p, c.c_uint64)(mm, lobby)
        # GetNumLobbyMembers can retain cached data after leaving. Ask the
        # backend for fresh data instead; the last member leaving destroys it.
        request = fn('SteamAPI_ISteamMatchmaking_RequestLobbyData', c.c_bool, c.c_void_p, c.c_uint64)
        deadline = time.monotonic() + 15
        absent = False
        while time.monotonic() < deadline and not absent:
            request(mm, lobby)
            tick = time.monotonic() + 1
            while time.monotonic() < tick:
                pump()
                absent = any(i == 505 and len(v) >= 17 and int.from_bytes(v[:8], 'little') == lobby and v[16] == 0 for i, v in events)
                if absent:
                    break
                time.sleep(.02)
        report['lobbyLeft'] = absent
        report['lobbyCleanupEvidence'] = 'fresh server query reports lobby absent' if absent else 'leave requested; server absence not confirmed'
        if not absent:
            report['ok'] = False
            report['cleanupError'] = 'Timed out confirming test lobby destruction'
        print('CLEANUP:', report['lobbyCleanupEvidence'], flush=True)
    if initialized:
        fn('SteamAPI_Shutdown', None)()
    output.write_text(json.dumps(report, indent=2), encoding='utf-8')
sys.exit(0 if report.get('ok') else 1)
