#!/usr/bin/env python3
import json,os,pathlib,shutil,struct,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
inspect=pathlib.Path(sys.argv[1]).resolve()
prefix=(root/'work/notproton-test/compatdata/480/pfx').resolve()
assert prefix.is_relative_to(root/'work') and (prefix/'user.reg').is_file(), 'An isolated work/ prefix is required'
assert (root/'work/windows-test-runtime/python.exe').is_file(), 'Run script/build_windows_test_runtime.sh first'
windows=lambda p:'Z:'+str(pathlib.Path(p).resolve()).replace('/','\\')
with tempfile.TemporaryDirectory(prefix='SteamlessTest-',dir=root/'work') as tmp:
    temp=pathlib.Path(tmp); steam=temp/'Steam'; game=steam/'steamapps/compatdata/480';game.mkdir(parents=True)
    (game/'pfx').symlink_to(prefix,target_is_directory=True)
    for name in ['notproton-build','notproton-msync']:
        if (prefix.parent/name).exists(): shutil.copy2(prefix.parent/name,game/name)
    plan=json.loads(subprocess.check_output([str(inspect),'--wine-plan',str(steam),'480',str(root/'outputs/Fluent Steam Mac.app/Contents/Resources/Helpers/SteamlessBridge/SteamlessBridge.exe')]))
    env=os.environ.copy();env.update(plan['environment']);env['WINEDEBUG']='-all';env['DOTNET_EnableWriteXorExecute']='0'
    request=temp/'request.json';response=temp/'response.json'
    def run(operation,file=''):
        response.unlink(missing_ok=True)
        request.write_text(json.dumps({'operation':operation,'plugins':windows(root/'work/steamless-probe/Plugins'),'file':windows(file) if file else ''}))
        p=subprocess.run([plan['executable'],*plan['arguments'],windows(request),windows(response)],env=env,capture_output=True,text=True,timeout=90)
        if not response.exists(): print(p.stdout,p.stderr);raise AssertionError('No bridge response: '+str(p.returncode))
        return json.loads(response.read_text())
    try:
        result=run('inspect');assert result['ok'],result
        print(json.dumps(result),flush=True)
        # Synthetic PE / SteamStub header, authored for this test. Never executed.
        binary=bytearray(0x600);binary[:2]=b'MZ';struct.pack_into('<I',binary,0x3c,0x80)
        binary[0x80:0x84]=b'PE\0\0';struct.pack_into('<HHIIIHH',binary,0x84,0x8664,2,0,0,0,240,0x22)
        optional=0x98;struct.pack_into('<H',binary,optional,0x20b)
        struct.pack_into('<III',binary,optional+4,0x400,0,0)
        struct.pack_into('<IIQ',binary,optional+16,0x2100,0x1000,0x140000000)
        struct.pack_into('<II',binary,optional+32,0x1000,0x200)
        struct.pack_into('<HH',binary,optional+40,6,0);struct.pack_into('<HH',binary,optional+48,6,0)
        struct.pack_into('<II',binary,optional+56,0x3000,0x200)
        struct.pack_into('<HH',binary,optional+68,3,0x8160)
        struct.pack_into('<QQQQII',binary,optional+72,0x100000,0x1000,0x100000,0x1000,0,16)
        for i,(name,rva,raw) in enumerate([(b'.text',0x1000,0x200),(b'.bind',0x2000,0x400)]):
            section=0x188+i*40;binary[section:section+8]=name.ljust(8,b'\0')
            struct.pack_into('<IIIIIIHHI',binary,section+8,0x200,rva,0x200,raw,0,0,0,0,0x60000020)
        binary[0x200:0x205]=b'\x31\xc0\xc3\x90\x90'
        header=bytearray(240);struct.pack_into('<IIQQIIQ',header,0,0x12345678,0xc0dec0df,0x140000000,0x140002100,0x100,0,0x1000)
        struct.pack_into('<II',header,56,480,4);struct.pack_into('<I',header,64,0x200);struct.pack_into('<QQ',header,72,0x1000,0x200)
        key=struct.unpack_from('<I',header)[0]
        for offset in range(4,240,4):
            key=struct.unpack_from('<I',header,offset)[0]^key;struct.pack_into('<I',header,offset,key)
        binary[0x410:0x500]=header
        signature=bytes.fromhex('E8 00 00 00 00 50 53 51 52 56 57 55 41 50');binary[0x500:0x500+len(signature)]=signature
        binary[0x520:0x528]=bytes.fromhex('48 8D 91 10 FF FF FF 41')
        fixture=temp/'synthetic-stub.exe';fixture.write_bytes(binary)
        result=run('unpack',fixture);assert result['ok'],result
        output=pathlib.Path(str(fixture)+'.unpacked.exe').read_bytes()
        assert fixture.read_bytes()==binary
        assert struct.unpack_from('<I',output,optional+16)[0]==0x1000
        assert struct.unpack_from('<H',output,0x86)[0]==1 and output[0x200:0x205]==binary[0x200:0x205]
        print('PASS: synthetic SteamStub 3.1 x64 unpacked, original entry point restored, .bind removed, code preserved; fixture was not executed',flush=True)
        result=run('unpack',root/'work/windows-test-runtime/python.exe')
        assert not result['ok'] and 'No supported SteamStub' in result['error'],result
        print('PASS: official unmodified plugins loaded under NotProton x86 .NET; unprotected PE rejected without changes',flush=True)
    finally:
        subprocess.run([env['WINESERVER'],'-k'],env=env)
        subprocess.run([env['WINESERVER'],'-w'],env=env,timeout=25)
