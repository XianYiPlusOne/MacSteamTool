#!/usr/bin/env python3
"""Production Swift + Windows helper against isolated synthetic game processes only."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile, time
ROOT=Path(__file__).resolve().parents[1]
INSPECT=ROOT/'.build/debug/MacSteamToolInspect'; HELPER=ROOT/'work/patch-probe-publish/PatchProbe.exe'
TEMPLATE=(ROOT/'work/notproton-test/compatdata/480/pfx').resolve(); PYTHON=ROOT/'work/windows-test-runtime'
assert TEMPLATE.is_relative_to(ROOT/'work') and HELPER.is_file() and (PYTHON/'python.exe').is_file()
win=lambda path:'Z:'+str(path.resolve()).replace('/','\\')
def run(root,action,ok=True):
 p=subprocess.run([str(INSPECT),'--exercise-patch-platform',str(root),action,str(HELPER)],capture_output=True,text=True,timeout=75)
 assert (p.returncode==0)==ok,(action,p.stdout,p.stderr)
 return p.stdout
with tempfile.TemporaryDirectory(prefix='patch-platform-',dir=ROOT/'work') as temp:
 root=Path(temp);(root/'.fluent-patch-fixture').touch()
 game=root/'Game';shutil.copytree(PYTHON,game);shutil.copy2(game/'python.exe',game/'FixtureGame.exe')
 payload=root/'Payload';payload.mkdir();module=PYTHON/'vcruntime140.dll'
 for name in ['fixture.dll','second.dll']:shutil.copy2(module,payload/name)
 wrong=root/'Wrong';wrong.mkdir();shutil.copy2(module,wrong/'fixture.dll')
 support=root/'Library/Application Support';prefix=support/'Steam/steamapps/compatdata/900001/pfx';prefix.parent.mkdir(parents=True)
 subprocess.run(['/bin/cp','-cR',str(TEMPLATE),str(prefix)],check=True)
 build=(TEMPLATE.parent/'notproton-build').read_text();(prefix.parent/'notproton-build').write_text(build)
 if (TEMPLATE.parent/'notproton-msync').exists():shutil.copy2(TEMPLATE.parent/'notproton-msync',prefix.parent/'notproton-msync')
 runner_name='crossover-'+build.splitlines()[0]
 actual=Path.home()/'Library/Application Support/notproton/runners'/runner_name/'CrossOver'
 assert actual.is_dir()
 runner=support/'notproton/runners'/runner_name;runner.mkdir(parents=True);(runner/'CrossOver').symlink_to(actual,target_is_directory=True)
 crossover=root/'CrossOver.app/Contents/SharedSupport';crossover.mkdir(parents=True);(crossover/'CrossOver').symlink_to(actual,target_is_directory=True)
 sentinel=root/'OtherGame/save.bin';sentinel.parent.mkdir();sentinel.write_bytes(b'keep-other-game')
 original_exe=(game/'FixtureGame.exe').read_bytes();original_registry=(prefix/'user.reg').read_bytes()
 (root/'runtime.json').write_text(json.dumps({'kind':'notProton'}))
 target_script=root/'fixture.py';target_script.write_text('''import ctypes as c,sys,pathlib,time
root=pathlib.Path(sys.argv[1]);k=c.WinDLL('kernel32');k.FreeLibrary.argtypes=[c.c_void_p]
handles=[]
for mode in sys.stdin:
 for handle in handles:k.FreeLibrary(handle)
 handles=[];mode=mode.strip()
 if mode=='stop':break
 names={'none':[],'wrong':[root/'Wrong/fixture.dll'],'one':[root/'Game/fixture.dll'],'all':[root/'Game/fixture.dll',root/'Game/second.dll']}[mode]
 for name in names:handles.append(c.WinDLL(str(name))._handle)
 print('READY:'+mode,flush=True)
''')
 plan=json.loads(subprocess.check_output([str(INSPECT),'--wine-plan',str(support/'Steam'),'900001',str(game/'FixtureGame.exe')]))
 env=os.environ.copy();env.update(plan['environment']);env['WINEDEBUG']='-all';server=env['WINESERVER']
 processes=[]
 def start(mode):
  p=subprocess.Popen([plan['executable'],*plan['arguments'],win(target_script),win(root)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
  processes.append(p);set_mode(p,mode);return p
 def set_mode(p,mode):
  p.stdin.write(mode+'\n');p.stdin.flush();assert p.stdout.readline().strip()=='READY:'+mode,'fixture did not start'
 def check(state):
  result=json.loads(run(root,'check'));assert result['state']==state,result
  print('PASS: runtime module check',state, 'loaded=',result['loaded'], 'missing=',result['missing'])
  return result
 try:
  run(root,'preview');run(root,'deploy');deployed_registry=(prefix/'user.reg').read_bytes();check('notRunning');run(root,'stopped')
  first=start('none');check('notLoaded');run(root,'stopped',False)
  set_mode(first,'wrong');check('notLoaded') # same bytes and basename, different file identity
  set_mode(first,'one');check('partial')
  set_mode(first,'all');result=check('loaded');assert len(result['loaded'])==2
  second=start('all');check('inconclusive');second.stdin.write('stop\n');second.stdin.flush();second.wait(timeout=10)
  # Direct CrossOver route uses the same isolated bottle and exact runner.
  (root/'runtime.json').write_text(json.dumps({'kind':'crossOver'}))
  run(root,'preview')
  # Redeploy only after stopping test processes, then check through the direct route.
  first.stdin.write('stop\n');first.stdin.flush();first.wait(timeout=10)
  subprocess.run([server,'-k'],env=env,check=False);subprocess.run([server,'-w'],env=env,check=True,timeout=25)
  # A Wine session may rewrite other registry sections. Verify the old restore detects it;
  # then restore the known deployed fixture snapshot before the deliberate test restore.
  (prefix/'user.reg').write_bytes(deployed_registry);run(root,'restore')
  assert not (game/'fixture.dll').exists() and (prefix/'user.reg').read_bytes()==original_registry
  run(root,'deploy');deployed_registry=(prefix/'user.reg').read_bytes();third=start('all');check('loaded')
  # A modified source must never retain a successful result.
  old=(game/'fixture.dll').read_bytes();(game/'fixture.dll').write_bytes(old+b'changed');run(root,'check',False);(game/'fixture.dll').write_bytes(old)
  old_game=(game/'FixtureGame.exe').read_bytes();(game/'FixtureGame.exe').write_bytes(old_game+b'changed');run(root,'check',False);(game/'FixtureGame.exe').write_bytes(old_game)
  third.stdin.write('stop\n');third.stdin.flush();third.wait(timeout=10)
  subprocess.run([server,'-k'],env=env,check=False);subprocess.run([server,'-w'],env=env,check=True,timeout=25)
  (prefix/'user.reg').write_bytes(deployed_registry);run(root,'restore')
  assert (game/'FixtureGame.exe').read_bytes()==original_exe and not (game/'fixture.dll').exists()
  assert (prefix/'user.reg').read_bytes()==original_registry and sentinel.read_bytes()==b'keep-other-game'
  print('PASS: NotProton and direct CrossOver preview/deploy/observed modules/restore; exact process and DLL identity, no-load/wrong-path/partial/all/ambiguous cases and changed-source rejection. Only a copied test prefix and synthetic Python game were used; real games/saves untouched.')
 finally:
  for p in processes:
   if p.poll() is None:p.terminate()
  subprocess.run([server,'-k'],env=env,check=False);subprocess.run([server,'-w'],env=env,check=False,timeout=25)
