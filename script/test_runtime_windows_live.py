#!/usr/bin/env python3
"""Explicit live Steam test, using only a disposable AppID 480 prefix under work/.
Requires the runtime extension and cached 480 tickets already configured in Steam.
Optional --achievement-roundtrip writes only ACH_WIN_ONE_GAME, starting locked.
Example:
  python3 script/test_runtime_windows_live.py --prefix work/notproton-test/compatdata/480/pfx \
      --tickets work/live-tests/runtime-native-tickets.json --achievement-roundtrip
Ticket contents are never printed. Windows result files remain private under work/.
"""
from pathlib import Path
import argparse,base64,json,os,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--prefix',required=True,type=Path);p.add_argument('--tickets',required=True,type=Path);p.add_argument('--achievement-roundtrip',action='store_true');p.add_argument('--hold',type=int,default=65);args=p.parse_args()
prefix=args.prefix.resolve();assert prefix.is_relative_to(root/'work') and prefix.name=='pfx' and prefix.parent.name=='480' and (prefix/'user.reg').is_file()
assert 0<=args.hold<=90
expected=json.loads(args.tickets.read_text());ownership=base64.b64decode(expected['ownershipTicket']);assert int.from_bytes(ownership[16:20],'little')==480
inspect=root/'.build/out/Products/Debug/FluentInspect';assert inspect.is_file(),'Build with script/build_and_run.sh first'
helper=root/'work/windows-test-runtime/python.exe';assert helper.is_file(), 'Run script/build_windows_test_runtime.sh first'
windows=lambda q:'Z:'+str(q).replace('/','\\')
with tempfile.TemporaryDirectory(dir=root/'work',prefix='LiveRuntimeWine-') as tmp:
    steam=Path(tmp)/'Steam';game=steam/'steamapps/compatdata/480';game.mkdir(parents=True);(game/'pfx').symlink_to(prefix,target_is_directory=True)
    (steam/'Steam.AppBundle').symlink_to(Path.home()/'Library/Application Support/Steam/Steam.AppBundle',target_is_directory=True)
    for name in ['notproton-build','notproton-msync']:(game/name).write_bytes((prefix.parent/name).read_bytes())
    plan=json.loads(subprocess.check_output([str(inspect),'--wine-plan',str(steam),'480',str(helper)]))
    env=os.environ.copy();env.update(plan['environment']);env['WINEDEBUG']='-all'
    server=env['WINESERVER']
    subprocess.run([server,'-k'],env=env,check=False);subprocess.run([server,'-w'],env=env,check=True,timeout=25)
    output=Path(tmp)/'windows-response.json';output.touch(mode=0o600)
    try:
        command=[plan['executable'],*plan['arguments'],windows(root/'script/test_runtime_windows.py'),windows(output),str(args.hold)]
        if args.achievement_roundtrip:command.append('--achievement-roundtrip')
        subprocess.run(command,env=env,check=True,timeout=160)
        result=json.loads(output.read_text());assert result['ok']
        assert all(expected[k]==result[k] for k in ['ownershipTicket','encryptedTicket'])
        print('PASS: both Windows ticket payloads exactly match the private native cache; no ticket content printed.')
    finally:
        subprocess.run([server,'-k'],env=env,check=False);subprocess.run([server,'-w'],env=env,check=True,timeout=25)
