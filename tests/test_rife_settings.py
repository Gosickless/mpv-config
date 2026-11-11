import importlib.util
from fractions import Fraction
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('rife_settings',Path(__file__).resolve().parents[1]/'rife/settings.py')
settings=importlib.util.module_from_spec(spec);spec.loader.exec_module(settings)

class SettingsTests(unittest.TestCase):
    def test_reference_frame_rates(self):
        for fps,target,factor in [(24,36,Fraction(3,2)),(24,60,Fraction(5,2)),(24,84,Fraction(7,2)),(24,0,Fraction(2)),(Fraction(24000,1001),60,Fraction(5,2)),(Fraction(30000,1001),60,Fraction(2))]:
            self.assertEqual(settings.selection({'target_fps':target},Fraction(fps))[1],factor)
    def test_tie_selects_lower(self):
        self.assertEqual(settings.selection({'target_fps':54},Fraction(24))[1],Fraction(2))
    def test_model_selection_and_invalid_values(self):
        for name,model in [('lite',4251),('standard',425),('heavy',4252)]:
            self.assertEqual(settings.selection({'model':name},Fraction(24))[0],model)
        for option in [{'model':'unknown'},{'target_fps':True},{'target_fps':12},{'target_fps':60.5}]:
            with self.assertRaises(ValueError):settings.selection(option,Fraction(24))
    def test_variants_retain_fp32_range(self):
        for model in [4251,4252]:
            backend=settings.backend_options(model)
            self.assertFalse(backend['fp16'])
            self.assertTrue(backend['tf32'])
        self.assertTrue(settings.backend_options(425)['fp16'])

if __name__=='__main__':unittest.main()
