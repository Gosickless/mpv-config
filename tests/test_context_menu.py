"""Exercise actual menu positioning with fixed widths and screen dimensions."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MPV=os.environ.get('RIFE_TEST_MPV')
SOURCE=Path(__file__).resolve().parents[1]/'scripts/context_menu.lua'

@unittest.skipUnless(MPV,'Set RIFE_TEST_MPV for the Lua positioning test')
class MenuTests(unittest.TestCase):
    def test_direction_inheritance_and_screen_edges(self):
        with tempfile.TemporaryDirectory(prefix='menu-direction-') as tmp:
            script=Path(tmp)/'test.lua'
            script.write_text('''local real_mp=mp
local fake={}
function fake.create_osd_overlay()
 return {update=function() return {x0=0,x1=200} end}
end
function fake.get_property_native(key,default)
 if key=='osd-dimensions' then return {w=1000,h=800} end
 return default
end
function fake.command_native(args) return args[2] end
function fake.register_script_message(...) end
mp=fake
package.loaded['mp.options']={read_options=function(options)
 options.padding_x=0;options.padding_y=0
end}
local file=assert(io.open(SOURCE,'rb'));local code=file:read('*a');file:close()
local scenario=[==[
local entries={{title='Test'}}
local function child()
 local parent=open_menus[#open_menus]
 add_menu(entries,parent.x+parent.width,10)
 return open_menus[#open_menus]
end
add_menu(entries,850,10)
assert(open_menus[1].x==800)
assert(child().x==600)
assert(child().x==400,'descendant switched back to the right')
assert(child().x==200)
assert(child().x==0)
assert(child().x==200,'left edge did not allow switching right')
open_menus={}
add_menu(entries,0,10)
assert(child().x==200)
assert(child().x==400)
assert(child().x==600)
assert(child().x==800)
assert(child().x==600)
assert(child().x==400,'right-edge flip was not inherited')
for _,menu in ipairs(open_menus) do
 assert(menu.x>=0 and menu.x+menu.width<=1000,'menu outside screen')
end
]==]
local ok,err=pcall(function() assert(loadstring(code..'\\n'..scenario))() end)
mp=real_mp
if not ok then real_mp.msg.error(tostring(err)) end
real_mp.commandv('quit',ok and '0' or '1')
'''.replace('SOURCE',json.dumps(str(SOURCE))),encoding='utf-8')
            result=subprocess.run([MPV,'--no-config','--load-scripts=no','--idle=yes',
                '--vo=null','--ao=null','--script='+str(script)],capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,(result.stdout+result.stderr).decode(errors='replace'))

if __name__=='__main__':unittest.main()
