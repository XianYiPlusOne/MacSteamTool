# Windows-side Spacewar-only RemoteStorage test. Uses a unique test file, never existing saves.
import ctypes as c,os,sys,json
os.environ['SteamAppId']='480';os.environ['SteamGameId']='480'
mode,name=sys.argv[1:3];assert mode in ('write','read-delete') and name.startswith('fluent-qa-') and name.endswith('.bin') and '/' not in name and '\\' not in name
lib=c.WinDLL(r'C:\Program Files (x86)\Steam\steamclient64.dll')
factory=lib.CreateInterface;factory.argtypes=[c.c_char_p,c.c_void_p];factory.restype=c.c_void_p
client=factory(b'SteamClient018',None);assert client

def method(obj,index,result,*params):
 table=c.cast(obj,c.POINTER(c.POINTER(c.c_void_p))).contents
 return c.CFUNCTYPE(result,c.c_void_p,*params)(table[index])
pipe=method(client,0,c.c_int)(client);assert pipe
user=method(client,2,c.c_int,c.c_int)(client,pipe);assert user
payload=bytes(range(256))*4+b'Fluent Steam Spacewar cloud test\0\xff'
try:
 utils=method(client,9,c.c_void_p,c.c_int,c.c_char_p)(client,pipe,b'SteamUtils010');assert utils and method(utils,9,c.c_uint32)(utils)==480
 remote=method(client,17,c.c_void_p,c.c_int,c.c_int,c.c_char_p)(client,user,pipe,b'STEAMREMOTESTORAGE_INTERFACE_VERSION016');assert remote
 enabled=method(remote,22,c.c_bool)(remote);assert enabled,'Spacewar cloud not enabled'
 exists=method(remote,13,c.c_bool,c.c_char_p);filename=name.encode()
 if mode=='write':
  assert not exists(remote,filename),'Refuse to overwrite existing file'
  buffer=c.create_string_buffer(payload)
  assert method(remote,0,c.c_bool,c.c_char_p,c.c_void_p,c.c_int)(remote,filename,buffer,len(payload)), 'FileWrite refused'
  print('PASS: Windows Spacewar RemoteStorage FileWrite accepted a new binary test file.',flush=True)
 buffer=c.create_string_buffer(len(payload)+1)
 count=method(remote,1,c.c_int,c.c_char_p,c.c_void_p,c.c_int)(remote,filename,buffer,len(buffer))
 assert count==len(payload) and buffer.raw[:count]==payload,'FileRead content mismatch'
 print('PASS: Windows Spacewar FileRead matches all binary bytes.',flush=True)
 if mode=='read-delete':
  assert method(remote,6,c.c_bool,c.c_char_p)(remote,filename),'FileDelete refused'
  assert not exists(remote,filename),'Test file still exists'
  print('PASS: Windows Spacewar FileDelete removed only the unique test file.',flush=True)
finally:
 method(client,4,None,c.c_int,c.c_int)(client,pipe,user);method(client,1,c.c_bool,c.c_int)(client,pipe)
