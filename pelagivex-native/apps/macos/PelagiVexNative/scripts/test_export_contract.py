import unittest
from export_model import inspect_shapes

class ExportContractTests(unittest.TestCase):
    def test_valid_segmentation(self):
        result = inspect_shapes({"var_1":[1,116,5376],"var_2":[1,32,128,128]},80)
        self.assertEqual(result["predictionName"],"var_1")
        self.assertEqual(result["maskChannels"],32)
    def test_detection_only_rejected(self):
        with self.assertRaises(ValueError):
            inspect_shapes({"p":[1,84,5376]},80)
    def test_end_to_end_layout_rejected(self):
        with self.assertRaises(ValueError):
            inspect_shapes({"p":[1,300,38],"m":[1,32,128,128]},80)
    def test_mismatched_class_count_rejected(self):
        with self.assertRaises(ValueError):
            inspect_shapes({"p":[1,116,5376],"m":[1,32,128,128]},1203)
    def test_ambiguous_outputs_rejected(self):
        with self.assertRaises(ValueError):
            inspect_shapes({"p":[1,116,5376],"m":[1,32,128,128],"m2":[1,32,128,128]},80)
    def test_memory_bound(self):
        with self.assertRaises(ValueError):
            inspect_shapes({"p":[1,116,999999],"m":[1,32,128,128]},80)

if __name__ == "__main__":
    unittest.main()
