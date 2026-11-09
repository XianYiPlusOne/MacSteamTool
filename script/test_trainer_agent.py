#!/usr/bin/env python3
"""Reparented agent lifecycle, using temporary preferences and no Wine bindings."""
from pathlib import Path
import json,os,signal,subprocess,sys,tempfile,time
root=Path(__file__).resolve().parents[1]
agent=root/'.build/debug/FluentTrainerAgent'
def alive(pid):
    return subprocess.run(['ps','-p',str(pid),'-o','pid='],capture_output=True).returncode==0
def until(test,timeout):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if test():return
        time.sleep(.2)
    raise AssertionError('agent lifecycle deadline exceeded')
with tempfile.TemporaryDirectory(prefix='trainer-agent-fixture-',dir=root/'work') as folder:
    area=Path(folder);settings=area/'settings.json';pidfile=area/'agent.pid'
    prefs=dict(steamPath=str(area/'Steam'),steamAppPath='/Applications/Steam.app',macSteamPath=str(area/'macsteam'),notProtonPath=str(area/'notproton'),luaPath=str(area/'Lua'),language='zh',theme='system',layout='cards',autoRefresh=False,autoMetadata=False,depotKeysURL='https://example.invalid/keys',tokensURL='https://example.invalid/tokens',manifestURL='https://example.invalid/{manifest}',trainers=[],independentTrainerMonitor=True)
    settings.write_text(json.dumps(prefs))
    code='import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.argv[1],sys.argv[2]],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);Path(sys.argv[3]).write_text(str(p.pid))'
    subprocess.run([sys.executable,'-c',code,str(agent),str(settings),str(pidfile)],check=True)
    pid=int(pidfile.read_text())
    try:
        until(lambda: subprocess.check_output(['ps','-p',str(pid),'-o','ppid=']).strip()==b'1',5)
        status=area/'TrainerAgent/status.json';until(status.exists,35)
        state=json.loads(status.read_text());assert state['bindings']=={}
        first=status.stat().st_mtime;until(lambda:status.stat().st_mtime>first,6)
        prefs['independentTrainerMonitor']=False;temporary=settings.with_suffix('.new');temporary.write_text(json.dumps(prefs));temporary.replace(settings)
        until(lambda:not alive(pid),8)
        print('PASS: agent survives launcher exit (PPID 1), reads isolated preferences, publishes heartbeats and exits when disabled; no Wine or login item used.')
    finally:
        if alive(pid):os.kill(pid,signal.SIGTERM)
    prefs['independentTrainerMonitor']=True;settings.write_text(json.dumps(prefs))
    process=subprocess.Popen([str(agent),str(settings)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        time.sleep(.5);process.terminate();assert process.wait(timeout=5)==0
        print('PASS: SIGTERM cleanly ends the independent agent, including during startup grace.')
    finally:
        if process.poll() is None:process.kill();process.wait()
