"""Run with Windows Python in an isolated prefix. Only creates temporary offline AppID 480 data."""
import ctypes as c,json,pathlib,shutil,sys,tempfile
with tempfile.TemporaryDirectory(prefix='FluentGoldberg-') as directory:
    root=pathlib.Path(directory);dll=root/'steam_api64.dll';shutil.copy2(sys.argv[1],dll)
    settings=root/'steam_settings';settings.mkdir()
    (settings/'steam_appid.txt').write_text('480\n')
    (settings/'configs.user.ini').write_text('[user::general]\naccount_name=Fluent Fixture\nlanguage=english\n[user::saves]\nlocal_save_path=./steam_settings/FluentOfflineSaves\n')
    (settings/'configs.main.ini').write_text('[main::connectivity]\ndisable_networking=1\noffline=1\n')
    (settings/'achievements.json').write_text(json.dumps([{'name':'FLUENT_FIXTURE','displayName':'Fixture','description':'Local test only','hidden':0}]))
    api=c.WinDLL(str(dll))
    def call(name,restype,args):
        f=getattr(api,name);f.restype=restype;f.argtypes=args;return f
    assert call('SteamAPI_Init',c.c_bool,[])(), 'GBE init failed'
    try:
        utils=call('SteamAPI_SteamUtils_v010',c.c_void_p,[])()
        assert utils and call('SteamAPI_ISteamUtils_GetAppID',c.c_uint32,[c.c_void_p])(utils)==480
        stats=call('SteamAPI_SteamUserStats_v012',c.c_void_p,[])()
        assert stats and call('SteamAPI_ISteamUserStats_GetNumAchievements',c.c_uint32,[c.c_void_p])(stats)==1
        get=call('SteamAPI_ISteamUserStats_GetAchievement',c.c_bool,[c.c_void_p,c.c_char_p,c.POINTER(c.c_bool)])
        state=c.c_bool();assert get(stats,b'FLUENT_FIXTURE',c.byref(state)) and not state.value
        assert call('SteamAPI_ISteamUserStats_SetAchievement',c.c_bool,[c.c_void_p,c.c_char_p])(stats,b'FLUENT_FIXTURE')
        assert call('SteamAPI_ISteamUserStats_StoreStats',c.c_bool,[c.c_void_p])(stats)
        assert get(stats,b'FLUENT_FIXTURE',c.byref(state)) and state.value
        assert call('SteamAPI_ISteamUserStats_ClearAchievement',c.c_bool,[c.c_void_p,c.c_char_p])(stats,b'FLUENT_FIXTURE')
        assert call('SteamAPI_ISteamUserStats_StoreStats',c.c_bool,[c.c_void_p])(stats)
        assert get(stats,b'FLUENT_FIXTURE',c.byref(state)) and not state.value
        print(json.dumps({'ok':True,'appID':480,'platform':'Goldberg Windows x64 / NotProton','offlineAchievementRoundTrip':True,'realSteamWrites':False}),flush=True)
    finally:
        call('SteamAPI_Shutdown',None,[])()
        c.windll.kernel32.FreeLibrary.argtypes=[c.c_void_p];c.windll.kernel32.FreeLibrary(api._handle)
