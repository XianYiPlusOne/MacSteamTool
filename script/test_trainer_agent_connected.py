#!/usr/bin/env python3
"""Real launchd -> packaged agent -> monitor configuration -> fake Wine process.
All files/bindings are temporary; no games, trainers, credentials or official login items.
"""
from pathlib import Path
import json,os,plistlib,shlex,shutil,subprocess,tempfile,time,uuid
root=Path(__file__).resolve().parents[1]
def wait(test,label,seconds=40):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if test():return
        time.sleep(.2)
    raise AssertionError(label)
with tempfile.TemporaryDirectory(prefix='agent-connected-',dir=root/'work') as temporary:
    area=Path(temporary);app=area/'Fixture.app';exe=app/'Contents/MacOS/FluentTrainerAgent';exe.parent.mkdir(parents=True)
    shutil.copy2(root/'.build/debug/FluentTrainerAgent',exe)
    helper=app/'Contents/Resources/Helpers/Windows';helper.mkdir(parents=True)
    for name in ['python.exe','trainer_monitor.py']:(helper/name).write_text('inert helper fixture')
    steam=area/'Steam';notproton=area/'notproton';pfx=steam/'steamapps/compatdata/480/pfx';pfx.mkdir(parents=True)
    (pfx.parent/'notproton-build').write_text('fixture\nrosetta\n')
    runner=notproton/'runners/crossover-fixture/CrossOver';wine=runner/'lib/wine/x86_64-unix/wine';wine.parent.mkdir(parents=True);server=runner/'bin/wineserver';server.parent.mkdir()
    server.write_text('#!/bin/sh\nexit 0\n');server.chmod(0o700)
    events=area/'children.jsonl';fake=area/'fake_wine.py'
    fake.write_text('''import json,sys,os,time
from pathlib import Path
def native(p):return Path(p[2:].replace('\\\\','/'))
config=native(sys.argv[3]);c=json.loads(config.read_text())
assert Path(sys.argv[1]).name=='python.exe' and native(sys.argv[2]).name=='trainer_monitor.py'
def event(kind):
 with open(EVENTS,'a') as f:f.write(json.dumps({'kind':kind,'pid':os.getpid(),'config':c})+'\\n')
event('start');print(json.dumps({'state':'watching'}),flush=True)
try:
 while not native(c['stop']).exists() and time.time()-native(c['lease']).stat().st_mtime<20:time.sleep(.1)
finally:event('stop')
'''.replace('EVENTS',repr(str(events))))
    wine.write_text('#!/bin/sh\nexec /usr/bin/env python3 '+shlex.quote(str(fake))+' "$@"\n');wine.chmod(0o700)
    game=area/'fixture-game.exe';trainer=area/'fixture-trainer.exe';game.write_text('not executable');trainer.write_text('not executable')
    binding=dict(id=str(uuid.uuid4()),appID=480,name='Test only',executable=str(trainer),autoLaunch=True,gameExecutable=str(game),autoKeys=['F1'],keyDelay=7)
    settings=area/'settings.json';prefs=dict(steamPath=str(steam),steamAppPath=str(area/'Steam.app'),macSteamPath=str(area/'macsteam'),notProtonPath=str(notproton),luaPath=str(area/'Lua'),language='zh',theme='system',layout='cards',autoRefresh=False,autoMetadata=False,depotKeysURL='https://example.invalid/keys',tokensURL='https://example.invalid/tokens',manifestURL='https://example.invalid/{manifest}',trainers=[binding],independentTrainerMonitor=True)
    def save():
        temp=settings.with_suffix('.new');temp.write_text(json.dumps(prefs));temp.replace(settings)
    def rows():return [json.loads(x) for x in events.read_text().splitlines()] if events.exists() else []
    def starts():return [r for r in rows() if r['kind']=='start']
    save();label='dev.fluentsteam.qa.'+uuid.uuid4().hex;domain='gui/'+str(os.getuid());plist=area/'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(Label=label,ProgramArguments=[str(exe),str(settings)],RunAtLoad=True,KeepAlive=dict(SuccessfulExit=False),ThrottleInterval=15,StandardOutPath=str(area/'agent.log'),StandardErrorPath=str(area/'agent.log'))))
    registered=False
    try:
        result=subprocess.run(['/bin/launchctl','bootstrap',domain,str(plist)],capture_output=True,text=True)
        assert result.returncode==0,result.stderr;registered=True
        wait(lambda:len(starts())==1,'launchd did not start the monitor through the packaged agent')
        c=starts()[0]['config'];assert c['keys']==['F1'] and c['delay']==7 and c['game'].endswith('fixture-game.exe')
        status=area/'TrainerAgent/status.json';wait(lambda:status.exists() and binding['id'].upper() in json.loads(status.read_text())['bindings'],'no binding heartbeat')
        binding['autoLaunch']=False;save();wait(lambda:any(x['kind']=='stop' for x in rows()),'unbind did not stop child',10)
        binding['autoLaunch']=True;binding['autoKeys']=['F2'];save();wait(lambda:len(starts())==2,'rebind did not restart monitor',12)
        assert starts()[-1]['config']['keys']==['F2']
        prefs['independentTrainerMonitor']=False;save();wait(lambda:len([x for x in rows() if x['kind']=='stop'])==2,'disable did not clean up child',12)
        print('PASS: actual temporary launchd service -> agent -> WineLaunch -> helper arguments/config -> heartbeat -> unbind/rebind -> shutdown cleanup; inert executable fixtures only.')
    finally:
        if registered:subprocess.run(['/bin/launchctl','bootout',domain+'/'+label],capture_output=True)
        for record in starts():
            try:os.kill(record['pid'],15)
            except ProcessLookupError:pass
        wait(lambda:subprocess.run(['/bin/launchctl','print',domain+'/'+label],capture_output=True).returncode!=0,'temporary launchd service leaked',20)
