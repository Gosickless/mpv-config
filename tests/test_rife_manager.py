"""Render the real manager against isolated installation records; no downloads."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
SOURCE=Path(__file__).resolve().parents[1]/'rife/manager.ps1'
class ManagerTests(unittest.TestCase):
    def render(self,record,old_version=False):
        with tempfile.TemporaryDirectory(prefix='rife-ui-') as tmp:
            folder=Path(tmp);root=folder/'安装目录';image=folder/'preview.png'
            if record:
                runtime=root/'runtime'/'fixture';runtime.mkdir(parents=True)
                (runtime/'runtime.json').write_text('{}')
                runtime_id=json.loads((SOURCE.parent/'runtime-lock.json').read_text())['id']
                (root/'active.json').write_text(json.dumps({'installed':True,'id':'old-runtime' if old_version else runtime_id,'root':str(runtime),'installed_at':'2026-11-06T08:00:00Z'},ensure_ascii=False),encoding='utf-8')
            process=subprocess.run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',str(SOURCE),'-Root',str(root),'-Mpv','C:\\test\\mpv.exe','-PreviewPath',str(image)],capture_output=True,timeout=20)
            self.assertEqual(process.returncode,0,process.stderr.decode(errors='replace'))
            self.assertTrue(image.exists())
            state=json.loads(Path(str(image)+'.json').read_text(encoding='utf-8-sig'))
            if not record:self.assertFalse(root.exists(),'Viewing the manager must not start installation')
            return state
    def test_first_open_does_not_install(self):
        state=self.render(False);self.assertFalse(state['installed']);self.assertEqual(state['primary'],'开始安装')
    def test_existing_install_with_unicode_path_opens_installed_view(self):
        state=self.render(True);self.assertTrue(state['installed']);self.assertEqual(state['primary'],'返回播放器');self.assertFalse(state['pause_visible'])
        self.assertTrue(state['uninstall_visible'])
    def test_old_runtime_offers_update_without_starting_download(self):
        state=self.render(True,old_version=True);self.assertFalse(state['installed']);self.assertEqual(state['primary'],'开始更新')
        self.assertEqual(state['title'],'补帧组件需要更新');self.assertTrue(state['uninstall_visible'])
if __name__=='__main__':unittest.main()
