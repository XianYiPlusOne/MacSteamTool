# Windows-side probe, invoked by test_runtime_windows_live.py in a private prefix.
# Read-only by default. --achievement-roundtrip explicitly unlocks and relocks
# ACH_WIN_ONE_GAME in Spacewar only, with a Steam success callback for each write.
import ctypes as c,json,os,time,sys,base64
os.environ['SteamAppId']='480';os.environ['SteamGameId']='480'
lib=c.WinDLL(r'C:\Program Files (x86)\Steam\steamclient64.dll')
factory=lib.CreateInterface;factory.argtypes=[c.c_char_p,c.c_void_p];factory.restype=c.c_void_p
client=factory(b'SteamClient018',None);assert client

def method(obj,index,result,*params):
    table=c.cast(obj,c.POINTER(c.POINTER(c.c_void_p))).contents
    return c.CFUNCTYPE(result,c.c_void_p,*params)(table[index])
pipe=method(client,0,c.c_int)(client);assert pipe
handle=method(client,2,c.c_int,c.c_int)(client,pipe);assert handle
try:
    utils=method(client,9,c.c_void_p,c.c_int,c.c_char_p)(client,pipe,b'SteamUtils010');assert utils
    assert method(utils,9,c.c_uint32)(utils)==480
    user=method(client,5,c.c_void_p,c.c_int,c.c_int,c.c_char_p)(client,handle,pipe,b'SteamUser023');assert user
    ticket=method(client,12,c.c_void_p,c.c_int,c.c_int,c.c_char_p)(client,handle,pipe,b'STEAMAPPTICKET_INTERFACE_VERSION001');assert ticket
    owned=c.create_string_buffer(4096);offsets=[c.c_uint32() for _ in range(4)]
    size=method(ticket,0,c.c_uint32,c.c_uint32,c.c_void_p,c.c_uint32,*([c.POINTER(c.c_uint32)]*4))(ticket,480,owned,4096,*[c.byref(v) for v in offsets])
    assert 148<=size<=4096 and int.from_bytes(owned.raw[offsets[0].value:offsets[0].value+4],'little')==480
    call=method(user,21,c.c_uint64,c.c_void_p,c.c_int)(user,None,0);assert call
    failed=c.c_bool();done=False
    for _ in range(400):
        done=method(utils,11,c.c_bool,c.c_uint64,c.POINTER(c.c_bool))(utils,call,c.byref(failed))
        if done or failed.value:break
        time.sleep(.05)
    assert done and not failed.value,'Encrypted ticket callback timeout'
    result=c.c_int32()
    assert method(utils,13,c.c_bool,c.c_uint64,c.c_void_p,c.c_int,c.c_int,c.POINTER(c.c_bool))(utils,call,c.byref(result),4,154,c.byref(failed)) and not failed.value and result.value==1, 'Callback 154 failed'
    encrypted=c.create_string_buffer(4096);en=c.c_uint32()
    assert method(user,22,c.c_bool,c.c_void_p,c.c_int,c.POINTER(c.c_uint32))(user,encrypted,4096,c.byref(en)) and 0<en.value<=4096
    stats=method(client,13,c.c_void_p,c.c_int,c.c_int,c.c_char_p)(client,handle,pipe,b'STEAMUSERSTATS_INTERFACE_VERSION012');assert stats
    assert method(stats,0,c.c_bool)(stats)
    count=0
    for _ in range(200):
        count=method(stats,14,c.c_uint32)(stats)
        if count:break
        time.sleep(.1)
    assert count==5
    rows=[]
    for i in range(count):
        name=method(stats,15,c.c_char_p,c.c_uint32)(stats,i);ach=c.c_bool();when=c.c_uint32()
        assert method(stats,9,c.c_bool,c.c_char_p,c.POINTER(c.c_bool),c.POINTER(c.c_uint32))(stats,name,c.byref(ach),c.byref(when))
        rows.append({'id':name.decode(),'achieved':ach.value,'unlockedAt':when.value})
    with open(sys.argv[1],'w') as f:json.dump({'ok':True,'ownershipTicket':base64.b64encode(owned.raw[:size]).decode(),'encryptedTicket':base64.b64encode(encrypted.raw[:en.value]).decode(),'achievements':rows},f)
    print('PASS: Windows x64 through installed NotProton: ownership, encrypted ticket, callback 154 and five Spacewar achievements.',flush=True)
    if len(sys.argv)>2:
        time.sleep(int(sys.argv[2]))
        print('PASS: Windows Spacewar session held for '+sys.argv[2]+' seconds.',flush=True)
    if '--achievement-roundtrip' in sys.argv:
        name=b'ACH_WIN_ONE_GAME'
        assert next(r for r in rows if r['id']==name.decode())['achieved'] is False, 'Require a locked Spacewar fixture achievement'
        class Callback(c.Structure):
            _fields_=[('user',c.c_int),('id',c.c_int),('data',c.c_void_p),('size',c.c_int)]
        getcb=lib.Steam_BGetCallback;getcb.argtypes=[c.c_int,c.POINTER(Callback),c.POINTER(c.c_uint64)];getcb.restype=c.c_bool
        freecb=lib.Steam_FreeLastCallback;freecb.argtypes=[c.c_int];freecb.restype=None
        def store(value):
            assert method(stats,7 if value else 8,c.c_bool,c.c_char_p)(stats,name)
            assert method(stats,10,c.c_bool)(stats)
            end=time.monotonic()+20
            while time.monotonic()<end:
                message=Callback();call=c.c_uint64()
                while getcb(pipe,c.byref(message),c.byref(call)):
                    success=False
                    if message.id==1102 and message.size>=12:
                        raw=c.string_at(message.data,message.size)
                        success=int.from_bytes(raw[:8],'little')==480 and int.from_bytes(raw[8:12],'little')==1
                    freecb(pipe)
                    if success:return
                time.sleep(.05)
            raise AssertionError('Spacewar StoreStats acknowledgement timed out')
        try:
            store(True)
            print('PASS: Windows Spacewar achievement unlock acknowledged by Steam.',flush=True)
        finally:
            store(False)
            print('PASS: Windows Spacewar achievement relocked with Steam acknowledgement.',flush=True)

finally:
    method(client,4,None,c.c_int,c.c_int)(client,pipe,handle)
    method(client,1,c.c_bool,c.c_int)(client,pipe)
