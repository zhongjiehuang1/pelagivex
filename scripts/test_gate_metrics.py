#!/usr/bin/env python3
"""Regression tests for the held-out detection evaluation rules."""
import unittest
from evaluate_gate import metrics, overlap

class GateMetricsTest(unittest.TestCase):
    def test_box_overlap(self):
        self.assertEqual(overlap([0,0,10,10],[0,0,10,10]),1)
        self.assertEqual(overlap([0,0,10,10],[20,20,30,30]),0)

    def test_duplicate_prediction_is_false_positive(self):
        items=[{'truth':[[0,0,10,10]],'detections':[
            {'score':.9,'box':[0,0,10,10]},
            {'score':.8,'box':[0,0,10,10]}]}]
        result=metrics(items,.7)
        self.assertEqual((result['tp'],result['fp'],result['fn']),(1,1,0))

    def test_missing_prediction_is_false_negative(self):
        result=metrics([{'truth':[[0,0,10,10]],'detections':[]}],.7)
        self.assertEqual((result['tp'],result['fp'],result['fn']),(0,0,1))

    def test_threshold_filters_prediction(self):
        items=[{'truth':[[0,0,10,10]],'detections':[{'score':.69,'box':[0,0,10,10]}]}]
        self.assertEqual(metrics(items,.7)['fn'],1)

if __name__=='__main__':
    unittest.main()
