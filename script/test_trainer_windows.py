"""Run with the bundled Windows Python inside a dedicated NotProton test prefix.
Uses inert copied Python executables; never sends keys or touches game saves.
"""
import importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile, time

runtime=pathlib.Path(sys.executable).parent
spec=importlib.util.spec_from_file_location('monitor',runtime/'trainer_monitor.py')
monitor=importlib.util.module_from_spec(spec); spec.loader.exec_module(monitor)
assert monitor.c.sizeof(monitor.INPUT)==40
assert monitor.parse_key('Ctrl+Num1')==[0x11,0x61]
assert os.getpid() in monitor.processes()

with tempfile.TemporaryDirectory(prefix='FluentTrainerTest-') as temp:
    root=pathlib.Path(temp); fixture=root/'runtime'; shutil.copytree(runtime,fixture)
    game=fixture/'game.exe'; trainer=fixture/'trainer.exe'
    shutil.copy2(fixture/'python.exe',game); shutil.copy2(fixture/'python.exe',trainer)
    (fixture/'python312._pth').write_text('python312.zip\n.\nimport site\n')
    (fixture/'sitecustomize.py').write_text("import os,sys,time\nif os.path.basename(sys.executable).lower()=='trainer.exe':\n time.sleep(120)\n os._exit(0)\n")
    stop=root/'stop'; config=root/'config.json'; log=root/'events.jsonl'
    config.write_text(json.dumps(dict(game=str(game),trainer=str(trainer),keys=[],delay=1,stop=str(stop))))
    children=[]
    def spawn_game():
        p=subprocess.Popen([str(game),'-c','import time;time.sleep(120)']); children.append(p); return p
    def trainer_pids(): return {pid for pid,path in monitor.processes().items() if path==monitor.norm(str(trainer))}
    def wait_for(predicate,label):
        until=time.monotonic()+20
        while time.monotonic()<until:
            if predicate(): return
            time.sleep(.2)
        raise AssertionError(label+'\n'+(log.read_text() if log.exists() else ''))
    def start_monitor():
        stop.unlink(missing_ok=True)
        with log.open('w') as handle:
            p=subprocess.Popen([sys.executable,str(runtime/'trainer_monitor.py'),str(config)],stdout=handle,stderr=handle)
        children.append(p); return p
    try:
        worker=start_monitor(); time.sleep(2)
        assert not trainer_pids(), 'trainer launched without game'
        g=spawn_game(); wait_for(lambda:len(trainer_pids())==1,'auto-launch')
        g.terminate(); g.wait(); wait_for(lambda:not trainer_pids(),'game exit cleanup')
        g=spawn_game(); wait_for(lambda:len(trainer_pids())==1,'second game launch')
        stop.touch(); assert worker.wait(timeout=15)==0
        wait_for(lambda:not trainer_pids(),'monitor stop cleanup')
        g.terminate(); g.wait()
        existing=subprocess.Popen([str(trainer)]); children.append(existing)
        wait_for(lambda:len(trainer_pids())==1,'existing fixture trainer')
        worker=start_monitor(); g=spawn_game()
        wait_for(lambda:'existing-trainer-kept' in log.read_text(),'existing trainer detection')
        stop.touch(); assert worker.wait(timeout=15)==0
        assert existing.poll() is None, 'existing trainer was incorrectly stopped'
        g.terminate(); g.wait(); existing.terminate(); existing.wait()
        settings=json.loads(config.read_text()); settings['lease']=str(root/'missing-lease'); config.write_text(json.dumps(settings))
        worker=start_monitor(); assert worker.wait(timeout=15)==0, 'orphan detection'
        print(json.dumps(dict(ok=True,platform='Windows x64 / NotProton',processEnumeration=True,autoLaunch=True,gameExitCleanup=True,secondLaunch=True,stopCleanup=True,preservedExistingTrainer=True,orphanLease=True,keysSent=0)),flush=True)
    finally:
        stop.touch()
        for p in reversed(children):
            if p.poll() is None:
                try: p.wait(timeout=4)
                except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=5)
