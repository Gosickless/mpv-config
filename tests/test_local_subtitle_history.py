"""Real-player persistence checks using disposable videos and subtitles."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

MPV=os.environ.get('RIFE_TEST_MPV')
SCRIPT=Path(__file__).resolve().parents[1]/'scripts/load_local_subtitle.lua'

@unittest.skipUnless(MPV,'Set RIFE_TEST_MPV to run the real-player check')
class SubtitleHistoryTests(unittest.TestCase):
    @contextmanager
    def player(self,folder,video,autoload='no'):
        pipe=r'\\.\pipe\subtitle-history-'+str(os.getpid())
        process=subprocess.Popen([MPV,'--config-dir='+str(folder),'--load-scripts=no','--script='+str(SCRIPT),
            '--vo=null','--ao=null','--pause=yes','--keep-open=yes','--sub-auto='+autoload,
            '--save-position-on-quit=no','--save-watch-history=no','--resume-playback=no',
            '--input-ipc-server='+pipe,str(video)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        connection=None
        def rpc(*command):
            connection.write((json.dumps({'command':command,'request_id':1})+'\n').encode())
            while True:
                answer=json.loads(connection.readline())
                if answer.get('request_id')==1:
                    if answer['error']!='success':raise RuntimeError(answer)
                    return answer.get('data')
        try:
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                try:connection=open(pipe,'r+b',buffering=0);break
                except OSError:
                    if process.poll() is not None:break
                    time.sleep(.1)
            if connection is None:
                process.terminate()
                output,error=process.communicate(timeout=10)
                self.fail((output+error).decode(errors='replace') or 'IPC unavailable')
            while time.monotonic()<deadline:
                try:
                    if rpc('get_property','video-params'):break
                except RuntimeError:pass
                time.sleep(.1)
            time.sleep(.2)
            yield rpc
        finally:
            process.terminate();process.communicate(timeout=10)
            if connection:connection.close()

    def test_restart_duplicates_missing_files_and_video_isolation(self):
        with tempfile.TemporaryDirectory(prefix='subtitle-history-') as tmp:
            folder=Path(tmp)
            for name in ['a','b']:
                (folder/(name+'.y4m')).write_bytes(b'YUV4MPEG2 W16 H16 F24:1 Ip A1:1 C420jpeg\n'+
                    (b'FRAME\n'+bytes([128])*384)*10)
            subtitles=[folder/'外部 字幕.srt',folder/'a.en.srt']
            for path in subtitles:path.write_text('1\n00:00:00,000 --> 00:00:01,000\nHello\n',encoding='utf-8')
            with self.player(folder,folder/'a.y4m') as rpc:
                for path in subtitles:rpc('sub-add',str(path),'select')
                deadline=time.monotonic()+5
                history=folder/'subtitle-history.json'
                while time.monotonic()<deadline:
                    if history.exists() and len(next(iter(json.loads(history.read_text()).values())))==2:break
                    time.sleep(.1)
                else:self.fail('External subtitles were not remembered')
            with self.player(folder,folder/'a.y4m','all') as rpc:
                tracks=rpc('get_property','track-list')
                self.assertEqual(sum(t['type']=='sub' for t in tracks),2,'Missing or duplicate subtitles after restart')
            subtitles[0].unlink()
            with self.player(folder,folder/'a.y4m') as rpc:
                self.assertEqual(sum(t['type']=='sub' for t in rpc('get_property','track-list')),1)
            with self.player(folder,folder/'b.y4m') as rpc:
                self.assertEqual(sum(t['type']=='sub' for t in rpc('get_property','track-list')),0)

if __name__=='__main__':unittest.main()
