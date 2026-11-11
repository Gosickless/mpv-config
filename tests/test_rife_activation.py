"""Optional real-player checks; no video, downloads, or installation changes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
MPV = os.environ.get('RIFE_TEST_MPV')
ROOT = os.environ.get('RIFE_TEST_ROOT')

@unittest.skipUnless(MPV and ROOT, 'Set RIFE_TEST_MPV and RIFE_TEST_ROOT for the real-player test')
class ActivationTests(unittest.TestCase):
    def test_same_process_activation_unicode_idempotence_and_version_guard(self):
        active = json.loads((Path(ROOT)/'active.json').read_text(encoding='utf-8-sig'))
        runtime = Path(active['root'])
        layout = json.loads((runtime/'runtime.json').read_text(encoding='utf-8-sig'))
        environment = {'runtime':str(runtime),'python':str(runtime/'python313.dll'),
                       'vsscript':str(runtime/layout['vsscript']), 'pythonpath':'C:/中文 测试/私有模块',
                       'directories':[str(runtime)]+[str(p) for p in {p.parent for p in runtime.rglob('*.dll')}]}
        with tempfile.TemporaryDirectory(prefix='rife-activation-') as tmp:
            folder=Path(tmp); result=folder/'result.json'; script=folder/'test.lua'
            script.write_text('''local mp=require 'mp'
local utils=require 'mp.utils'
local ffi=require 'ffi'
local apply=dofile(MODULE)
local env=utils.parse_json([==[PAYLOAD]==])
local ok,err=pcall(function()
 apply(env);apply(env)
 ffi.cdef[[unsigned long __stdcall GetEnvironmentVariableW(const wchar_t*,wchar_t*,unsigned long);]]
 local key=ffi.new('wchar_t[11]',{80,89,84,72,79,78,80,65,84,72,0})
 local buffer=ffi.new('wchar_t[32768]')
 assert(ffi.C.GetEnvironmentVariableW(key,buffer,32768)>0)
 local count=ffi.C.WideCharToMultiByte(65001,0,buffer,-1,nil,0,nil,nil)
 local text=ffi.new('char[?]',count)
 ffi.C.WideCharToMultiByte(65001,0,buffer,-1,text,count,nil,nil)
 assert(ffi.string(text)==env.pythonpath,'Unicode process environment differs')
 env.vsscript=env.vsscript..'.other-version'
 local changed,message=pcall(apply,env)
 assert(not changed and tostring(message):find('组件版本已变化',1,true),'Version switch was not rejected')
end)
local file=assert(io.open(RESULT,'wb'));file:write(utils.format_json({ok=ok,error=tostring(err)}));file:close()
mp.commandv('quit',ok and '0' or '1')
'''.replace('MODULE',json.dumps(str(REPO/'rife/environment.lua')))
                 .replace('PAYLOAD',json.dumps(environment,ensure_ascii=False))
                 .replace('RESULT',json.dumps(str(result))),encoding='utf-8')
            env=os.environ.copy()
            for key in ['VSSCRIPT_PATH','MPV_RIFE_ROOT','PYTHONHOME','PYTHONPATH']:env.pop(key,None)
            env['PATH']=os.pathsep.join(p for p in env['PATH'].split(os.pathsep) if not p.lower().startswith(ROOT.lower()))
            process=subprocess.run([MPV,'--no-config','--load-scripts=no','--idle=yes','--vo=null','--ao=null',
                                    '--script='+str(script)],env=env,capture_output=True,timeout=20)
            self.assertEqual(process.returncode,0,process.stderr.decode(errors='replace'))
            self.assertTrue(json.loads(result.read_text(encoding='utf-8'))['ok'])

if __name__=='__main__': unittest.main()
