"""Exercise the real Lua playback controller with a deterministic mp API."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
MPV = os.environ.get('RIFE_TEST_MPV') or shutil.which('mpv')

@unittest.skipUnless(MPV, 'Set RIFE_TEST_MPV to run the Lua controller tests')
class PlaybackTests(unittest.TestCase):
    def run_lua(self, scenario):
        with tempfile.TemporaryDirectory(prefix='rife-playback-') as tmp:
            script = Path(tmp)/'test.lua'
            script.write_text('''local real_mp=require 'mp'
local utils=require 'mp.utils'
local props={pause=false,['time-pos']=300,['estimated-vf-fps']=60,avsync=0}
local observers,events,messages={},{},{}
local filtered=false
local now=0
local timer
local fake={msg={info=function(s) messages[#messages+1]=s end,error=function() end}}
function fake.get_property_native(k)
 if k=='vf' then return filtered and {{label='mpv_rife'}} or {} end
 return props[k]
end
function fake.get_property_number(k,default) return props[k] or default end
function fake.get_property_bool(k,default) if props[k]==nil then return default end return props[k] end
function fake.get_time() return now end
function fake.set_property_native(k,v) props[k]=v end
function fake.command_native(args)
 if args[1]=='expand-path' then return CONFIG end
 if args[1]=='vf' then filtered=args[2]=='add' end
end
function fake.commandv(...) end
function fake.osd_message(...) end
function fake.enable_messages(...) end
function fake.register_script_message(...) end
function fake.observe_property(k,kind,fn) observers[k]=fn end
function fake.register_event(k,fn) events[k]=fn end
function fake.add_periodic_timer(_,fn) timer={kill=function() end};timer.tick=fn;return timer end
package.loaded['mp']=fake
package.loaded['mp.options']={read_options=function() end}
local file=assert(io.open(SOURCE,'rb'));local code=file:read('*a');file:close()
assert(loadstring(code..'\\nrequested=true;attach(0,{output_fps=60})'))()
local function tick(sync)
 now=now+.5;props['time-pos']=props['time-pos']+.5;props['audio-pts']=props['time-pos']
 props.avsync=sync or 0;timer.tick()
end
local function enabled_messages()
 local count=0;for _,s in ipairs(messages) do if s=='AI 补帧已开启' then count=count+1 end end
 return count
end
local ok,err=pcall(function()
SCENARIO
end)
if not ok then real_mp.msg.error(tostring(err)) end
real_mp.commandv('quit',ok and '0' or '1')
'''.replace('CONFIG', json.dumps(str(REPO)))
               .replace('SOURCE', json.dumps(str(REPO/'scripts/rife.lua')))
               .replace('SCENARIO', scenario), encoding='utf-8')
            result=subprocess.run([MPV,'--no-config','--load-scripts=no','--idle=yes',
                                   '--vo=null','--ao=null','--script='+str(script)],
                                  capture_output=True,timeout=15)
            self.assertEqual(result.returncode,0,(result.stdout+result.stderr).decode(errors='replace'))

    def test_resume_and_seek_do_not_repeat_enabled_message(self):
        self.run_lua('''for i=1,10 do tick() end
assert(enabled_messages()==1)
props.pause=true;observers.pause('pause',true)
props.pause=false;observers.pause('pause',false)
for i=1,10 do tick() end
events.seek();for i=1,10 do tick() end
assert(enabled_messages()==1,'pause/seek repeated the enabled notification')
assert(props['user-data/rife'].phase=='开启')''')

    def test_persistent_desync_disables_interpolation(self):
        self.run_lua('''for i=1,10 do tick() end
tick(.4);tick(.5);tick(.6)
assert(not filtered,'persistent desync left the slow filter running')
assert(not props['user-data/rife'].requested)
assert(props['user-data/rife'].phase~='开启')''')

    def test_seek_and_pause_do_not_trigger_performance_failure(self):
        self.run_lua('''for i=1,10 do tick() end
events.seek();tick(1);tick(.5);tick();tick()
props.pause=true;observers.pause('pause',true)
for i=1,10 do tick(1) end
props.pause=false;observers.pause('pause',false)
tick(.5);tick();for i=1,10 do tick() end
assert(filtered,'transient seek/pause desync disabled the filter')''')

if __name__=='__main__': unittest.main()
