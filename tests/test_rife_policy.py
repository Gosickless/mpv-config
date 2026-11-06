"""CPU-only tests; no NVIDIA downloads or inference."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('rife_policy',ROOT/'rife/policy.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)

class PolicyTests(unittest.TestCase):
    def source(self, **changes):
        data=dict(width=3840,height=2160,fps='23.976',matrix='bt.709',transfer='bt.1886')
        data.update(changes);return data
    def test_resolution_and_fps_not_silently_reduced(self):
        for w,h in [(1920,1080),(2560,1440),(3840,2160)]:
            result=policy.validate(self.source(width=w,height=h))
            self.assertEqual(result[:2],(w,h))
        for change in [dict(width=7680),dict(width=1921),dict(fps='60')]:
            with self.assertRaises(ValueError):policy.validate(self.source(**change))
    def test_hdr_requires_explicit_experimental_consent(self):
        with self.assertRaises(ValueError):policy.validate(self.source(transfer='pq',matrix='bt.2020-ncl'))
        self.assertTrue(policy.validate(self.source(transfer='pq',matrix='bt.2020-ncl',experimental_hdr=True))[3])
    def test_unknown_and_unsupported_sources_fail_closed(self):
        for change in [dict(transfer='hlg'),dict(matrix='unknown'),dict(transfer='unknown'),dict(interlaced=True),dict(dolby_vision=True)]:
            with self.assertRaises(ValueError):policy.validate(self.source(**change))
    def test_lock_has_fixed_https_assets(self):
        lock=json.loads((ROOT/'rife/runtime-lock.json').read_text())
        names=set()
        for asset in lock['assets']:
            self.assertNotIn(asset['name'],names);names.add(asset['name'])
            self.assertRegex(asset['sha256'],r'^[0-9a-f]{64}$')
            self.assertTrue(asset['url'].startswith('https://'))
            self.assertGreater(asset['size'],0)
        self.assertIn('trt.7z.002',names)

if __name__=='__main__':unittest.main()
