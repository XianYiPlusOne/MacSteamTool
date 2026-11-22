#!/usr/bin/env python3
"""Exercise the app's real WineLaunch adapter inside an existing, isolated test prefix.
Usage: test_wine_adapter.py MacSteamToolInspect test-prefix/pfx bundled-Windows-helper-directory
No installed game prefix is accepted. No keys or achievement writes are issued.
"""
import base64, json, os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
inspect, prefix, runtime = map(lambda s:pathlib.Path(s).resolve(), sys.argv[1:])
assert prefix.is_relative_to(root/'work') and prefix.name=='pfx' and (prefix/'user.reg').is_file()
assert runtime.is_dir() and inspect.is_file()
windows=lambda p:'Z:'+str(pathlib.Path(p).resolve()).replace('/','\\')
with tempfile.TemporaryDirectory(prefix='WineAdapter-', dir=root/'work') as temp:
    steam=pathlib.Path(temp)/'Steam'; (steam/'steamapps').mkdir(parents=True)
    fixture_game=steam/'steamapps/compatdata'/prefix.parent.name; fixture_game.mkdir(parents=True)
    (fixture_game/'pfx').symlink_to(prefix, target_is_directory=True)
    for name in ['notproton-build','notproton-msync']:
        if (prefix.parent/name).exists(): shutil.copy2(prefix.parent/name,fixture_game/name)
    plan=json.loads(subprocess.check_output([str(inspect),'--wine-plan',str(steam),prefix.parent.name,str(runtime/'python.exe')]))
    env=os.environ.copy();env.update(plan['environment']);env['WINEDEBUG']='-all';env['SteamAppId']='480';env['SteamGameId']='480'
    server=env['WINESERVER']
    def run(arguments):
        process=subprocess.run([plan['executable'],*plan['arguments'],*arguments],env=env,capture_output=True,text=True,timeout=120)
        print(process.stdout, end='');
        if process.returncode: print(process.stderr); raise AssertionError('Wine helper failed: '+str(process.returncode))
    # This stops only the explicitly supplied fixture prefix, never a user game prefix.
    subprocess.run([server,'-k'],env=env,check=False)
    subprocess.run([server,'-w'],env=env,check=True,timeout=25)
    registry=prefix/'user.reg'; original=registry.read_bytes()
    try:
        registry.write_bytes(base64.b64decode(subprocess.check_output([str(inspect),'--wine-override-preview',str(registry),'FixtureGame.exe','version,winmm'])))
        probe=pathlib.Path(temp)/'registry_probe.py'
        probe.write_text("import winreg,json\nk=winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\\Wine\\AppDefaults\\FixtureGame.exe\\DllOverrides')\nassert all(winreg.QueryValueEx(k,n)[0]=='native,builtin' for n in ['version','winmm'])\nprint(json.dumps({'ok':True,'registryOverrides':'app-scoped native,builtin','adapter':'WineLaunch.prepare'}),flush=True)\n")
        run([windows(probe)])
    finally:
        subprocess.run([server,'-k'],env=env,check=False)
        subprocess.run([server,'-w'],env=env,check=True,timeout=25)
        registry.write_bytes(original)
    if os.environ.get('FLUENT_GOLDBERG_DLL'):
        run([windows(root/'script/test_goldberg_windows.py'), windows(os.environ['FLUENT_GOLDBERG_DLL'])])
    subprocess.run([server,'-w'],env=env,check=True,timeout=25)
    print('PASS: app Wine adapter and isolated Windows integration; registry restored; keysSent=0')
