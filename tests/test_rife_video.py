"""Optional GPU regression against a caller-supplied SDR video; no downloads."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

REPO=Path(__file__).resolve().parents[1]
MPV=os.environ.get('RIFE_TEST_MPV')
ROOT=os.environ.get('RIFE_TEST_ROOT')
VIDEO=os.environ.get('RIFE_TEST_VIDEO')

@unittest.skipUnless(MPV and ROOT and VIDEO, 'Set RIFE_TEST_MPV, RIFE_TEST_ROOT and RIFE_TEST_VIDEO')
class VideoTests(unittest.TestCase):
    def test_finite_frames_and_realtime_or_safe_fallback(self):
        with tempfile.TemporaryDirectory(prefix='rife-video-') as tmp:
            folder=Path(tmp)
            bridge=folder/'interpolate.vpy'
            code=(REPO/'rife/interpolate.vpy').read_text(encoding='utf-8')
            code=code.replace('str(Path(__file__).resolve().parent)',repr(str(REPO/'rife')))
            check='''import math
def check_finite(n, f):
    for plane in range(3):
        data=f[plane]
        for y in range(0, f.height, 67):
            for x in range(0, f.width, 113):
                if not math.isfinite(data[y,x]):
                    raise ValueError('NONFINITE RGB output frame '+str(n))
    return f
result=core.std.ModifyFrame(result,clips=result,selector=check_finite)
'''
            bridge.write_text(code.replace('result = core.resize.Bicubic(result,',
                                           check+'result = core.resize.Bicubic(result,'),encoding='utf-8')
            script=folder/'rife.lua'
            code=(REPO/'scripts/rife.lua').read_text(encoding='utf-8')
            script.write_text(code.replace("utils.join_path(config, 'rife/interpolate.vpy')",
                                           json.dumps(str(bridge).replace('\\','/'))),encoding='utf-8')
            for model,target in [('standard',60),('heavy',0),('lite',0),('standard',120)]:
                with self.subTest(model=model,target=target):
                    self.check_playback(folder,script,model,target)

    def check_playback(self,folder,script,model,target):
        pipe=r'\\.\pipe\rife-regression-'+str(os.getpid())
        log=folder/(model+'-'+str(target)+'.log')
        args=[MPV,'--config-dir='+str(REPO),'--load-scripts=no','--script='+str(script),
              '--script-opts=rife-runtime_root='+ROOT+',rife-model='+model+',rife-target_fps='+str(target),
              '--vo=null','--ao=null','--hwdec=no','--pause=yes','--start=300',
              '--save-position-on-quit=no','--save-watch-history=no','--resume-playback=no',
              '--input-ipc-server='+pipe,'--log-file='+str(log),VIDEO]
        env=os.environ.copy()
        for key in ['PYTHONHOME','PYTHONPATH','VSSCRIPT_PATH','MPV_RIFE_ROOT']:env.pop(key,None)
        process=subprocess.Popen(args,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        connection=None
        serial=0
        def rpc(*command):
            nonlocal serial
            serial+=1
            connection.write((json.dumps({'command':command,'request_id':serial})+'\n').encode())
            while True:
                line=connection.readline()
                if not line:raise RuntimeError('Player disconnected')
                answer=json.loads(line)
                if answer.get('request_id')==serial:
                    if answer.get('error')!='success':raise RuntimeError(answer)
                    return answer.get('data')
        def prop(key):
            try:return rpc('get_property',key)
            except RuntimeError:return None
        try:
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                try:connection=open(pipe,'r+b',buffering=0);break
                except OSError:time.sleep(.1)
            self.assertIsNotNone(connection,'IPC unavailable')
            while not prop('video-params') and time.monotonic()<deadline:time.sleep(.1)
            rpc('script-message-to','rife','toggle')
            rpc('set_property','pause',False)
            deadline=time.monotonic()+180
            requested=False
            while time.monotonic()<deadline:
                state=prop('user-data/rife') or {}
                requested=requested or state.get('requested',False)
                self.assertNotEqual(state.get('phase'),'不可用',state)
                if state.get('phase')=='开启' or requested and not state.get('requested',True):break
                time.sleep(.1)
            else:self.fail('Interpolation did not start')
            samples=[]
            for _ in range(10):
                time.sleep(.5)
                samples.append(prop('avsync'))
            state=prop('user-data/rife')
            self.assertNotIn(state['phase'],['关闭','正在检查','正在准备','不可用'],state)
            self.assertTrue(all(value is not None and abs(value)<.2 for value in samples[-3:]),samples)
            if model=='standard' and target==60:self.assertTrue(state['active'],state)
            self.assertNotIn('NONFINITE',log.read_text(encoding='utf-8',errors='replace'))
        finally:
            if process.poll() is None:
                try:
                    if connection:rpc('quit')
                    process.wait(timeout=10)
                except (OSError,RuntimeError,subprocess.TimeoutExpired):
                    process.kill();process.wait(timeout=10)
            if connection:connection.close()

if __name__=='__main__':unittest.main()
