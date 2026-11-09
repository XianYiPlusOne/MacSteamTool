#!/usr/bin/env python3
"""Native hooks against the user's installed binaries, with a private data root and no Steam IPC."""
from pathlib import Path
import os, json, struct, subprocess, tempfile, shutil, hashlib, base64, argparse
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--tickets',type=Path);p.add_argument('--layout', choices=['standard','descriptor','unaligned'], default='standard');args=p.parse_args()
steam=Path.home()/'Library/Application Support/Steam'
client=steam/'Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib'
mac=Path('/Applications/Steam.app/Contents/MacOS/macsteam.dylib')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
# Keep real stats and all cloud-save roots unchanged; compare relevant stats inputs afterward.
real_stats=list((steam/'appcache/stats').glob('*480.bin'));before={p:digest(p) for p in real_stats}
with tempfile.TemporaryDirectory(prefix='runtime-fixture-',dir=root/'work') as tmp:
    fixture=Path(tmp);(fixture/'.fluent-fixture').touch();(fixture/'CloudRedirect').mkdir();(fixture/'Steam/config').mkdir(parents=True);(fixture/'Steam/appcache/stats').mkdir(parents=True)
    sid=76561197960265729
    ownership=bytearray(178);struct.pack_into('<I',ownership,0,50);struct.pack_into('<Q',ownership,8,sid);struct.pack_into('<I',ownership,16,480)
    if args.layout != 'standard':
        ownership=bytearray(220);struct.pack_into('<Q',ownership,8,sid)
        offset=50 if args.layout=='descriptor' else 51
        struct.pack_into('<II',ownership,0,offset if args.layout=='descriptor' else 92,4 if args.layout=='descriptor' else 0)
        struct.pack_into('<I',ownership,offset,480)
    encrypted=b'\x08\x01\x12\x01\0'
    if args.tickets:
        private=json.loads(args.tickets.read_text());ownership=base64.b64decode(private['ownershipTicket']);encrypted=base64.b64decode(private['encryptedTicket']);sid=struct.unpack_from('<Q',ownership,8)[0]
    account=sid&0xffffffff
    (fixture/'Steam/config/loginusers.vdf').write_text(f'"users"\n{{\n"{sid}"\n{{\n"MostRecent" "1"\n}}\n}}\n')
    schema=steam/'appcache/stats/UserGameStatsSchema_480.bin';shutil.copyfile(schema,fixture/'Steam/appcache/stats'/schema.name)
    stats=steam/f'appcache/stats/UserGameStats_{account}_480.bin'
    if not stats.exists():stats=next((steam/'appcache/stats').glob('UserGameStats_*_480.bin'))
    shutil.copyfile(stats,fixture/f'Steam/appcache/stats/UserGameStats_{account}_480.bin')
    config={'enabled':False,'apps':[],'sync_achievements':True,'sync_playtime':True,'stats_apps':[480],'provider':'folder','token_paths':{'folder':str(fixture/'provider')}}
    (fixture/'CloudRedirect/config.json').write_text(json.dumps(config))
    runtime=fixture/'CloudRedirect/runtime.json';runtime.write_text(json.dumps({'presence':'none','presenceApps':{'480':'Spacewar'},'tickets':{'480':{'enabled':True,'ownership':ownership.hex(),'encrypted':encrypted.hex()}}}));runtime.chmod(0o600)
    proc=subprocess.run([str(root/'work/cloud-build/FluentRuntimeProbe'),str(client),str(mac),str(fixture)],capture_output=True,text=True,timeout=130)
    (root/'work/evidence/runtime-native-private.log').write_text(proc.stdout+'\n'+proc.stderr)
    for line in proc.stdout.splitlines():
        if line.startswith('PASS:'):print(line,flush=True)
    if proc.returncode:
        print('Native probe failed:',proc.returncode);print(proc.stderr[-3000:]);raise SystemExit(1)
    # Cloud account metadata survived the complete provider path, with no nonselected entry.
    candidates=list((fixture/'provider').rglob('stats.json'))
    assert candidates,'No provider stats.json uploaded'
    blob=json.loads(candidates[0].read_text());assert '480' in blob and '481' not in blob
    assert blob['480']['playtime']['windows']>=1,blob['480']['playtime']
    assert blob['480']['stats'], 'Cloud stats values missing'
    assert blob['480']['achievements'], 'Cloud achievement block missing'
    for p,d in before.items():assert digest(p)==d, f'Real stats modified: {p.name}'
    print('PASS: cloud-folder statistics upload and Windows minutes verified; original Spacewar statistics files unchanged.')
