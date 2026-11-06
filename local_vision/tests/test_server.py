import http.client
import json
import sys
import threading
import unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import Service, target_depth


class FakeDetector:
    info = {'name': 'fake'}
    def detect(self, image):
        return [{'label': 'object', 'confidence': 0.9, 'box': [0, 0, 8, 8]}]


class FakeOwl:
    def detect(self, image, prompts):
        return [{'label': prompts[0], 'confidence': 0.8, 'box': [0, 0, 8, 8]}]


class FakeDepth:
    info = {'name': 'fake'}
    def estimate(self, image):
        return np.full(image.shape[:2], 2.0, dtype=np.float32)


class FakeLargeDepth:
    def estimate(self, image):
        return np.full(image.shape[:2], 4.0, dtype=np.float32)


class FakeMixedDepth:
    use_mixed = True
    def estimate(self, image):
        return np.full(image.shape[:2], 3.0, dtype=np.float32)


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = Service(('127.0.0.1', 0), FakeDetector(), FakeDepth())
        cls.http.owl = FakeOwl()
        cls.http.owl_large = FakeOwl()
        cls.http.large_depth = FakeLargeDepth()
        cls.http.pro_depth = FakeLargeDepth()
        cls.http.mixed_depth = FakeMixedDepth()
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        conn.request(method, path, body, headers or {})
        response = conn.getresponse()
        result = response.status, response.read()
        conn.close()
        return result

    def test_scaled_distance_and_frame_coordinates(self):
        _, jpeg = cv2.imencode('.jpg', np.zeros((8, 8, 3), dtype=np.uint8))
        body = (b'--x\r\nContent-Disposition: form-data; name="scale"\r\n\r\n1.5\r\n'
                b'--x\r\nContent-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
                b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n--x--\r\n')
        status, data = self.request('POST', '/api/analyze', body, {'Content-Type': 'multipart/form-data; boundary=x'})
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertEqual((result['width'], result['height']), (8, 8))
        self.assertEqual(result['detections'][0]['distance_m'], 3.0)
        self.assertIsNone(result['depth_grid'])
        offset_body = body.replace(b'--x\r\nContent-Disposition: form-data; name="image"', b'--x\r\nContent-Disposition: form-data; name="offset"\r\n\r\n-0.5\r\n--x\r\nContent-Disposition: form-data; name="image"')
        status, data = self.request('POST', '/api/analyze', offset_body, {'Content-Type': 'multipart/form-data; boundary=x'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['detections'][0]['distance_m'], 2.5)
        negative_body = offset_body.replace(b'\r\n-0.5\r\n', b'\r\n-4\r\n')
        status, data = self.request('POST', '/api/analyze', negative_body, {'Content-Type': 'multipart/form-data; boundary=x'})
        self.assertEqual(status, 200)
        self.assertIsNone(json.loads(data)['detections'][0]['distance_m'])
        bad_offset = offset_body.replace(b'\r\n-0.5\r\n', b'\r\n-1000\r\n')
        status, _ = self.request('POST', '/api/analyze', bad_offset, {'Content-Type': 'multipart/form-data; boundary=x'})
        self.assertEqual(status, 400)

    def test_same_frame_comparison_uses_uncalibrated_values(self):
        _, jpeg = cv2.imencode('.jpg', np.zeros((8, 8, 3), dtype=np.uint8))
        body = (b'--x\r\nContent-Disposition: form-data; name="scale"\r\n\r\n0.5\r\n'
                b'--x\r\nContent-Disposition: form-data; name="compare_depth"\r\n\r\n1\r\n'
                b'--x\r\nContent-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
                b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n--x--\r\n')
        status, data = self.request('POST', '/api/analyze', body, {'Content-Type': 'multipart/form-data; boundary=x'})
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertEqual(result['detections'][0]['distance_m'], 1.0)
        self.assertEqual(result['depth_grid']['values'][0], 2.0)
        self.assertEqual(result['depth_grid_large']['values'][0], 4.0)
        self.assertEqual(result['depth_grid']['width'], result['depth_grid_large']['width'])
        self.assertEqual(result['depth_candidate_name'], 'Large')
        pro_body = body.replace(b'--x\r\nContent-Disposition: form-data; name="image"', b'--x\r\nContent-Disposition: form-data; name="compare_model"\r\n\r\npro\r\n--x\r\nContent-Disposition: form-data; name="image"')
        status, data = self.request('POST', '/api/analyze', pro_body, {'Content-Type': 'multipart/form-data; boundary=x'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['depth_candidate_name'], 'Depth Pro')

    def test_live_mixed_mode_and_standard_comparison(self):
        _, jpeg = cv2.imencode('.jpg', np.zeros((8, 8, 3), dtype=np.uint8))
        prefix = (b'--x\r\nContent-Disposition: form-data; name="depth_mode"\r\n\r\nmixed\r\n')
        image_part = (b'--x\r\nContent-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
                      b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n--x--\r\n')
        headers = {'Content-Type': 'multipart/form-data; boundary=x'}
        status, data = self.request('POST', '/api/analyze', prefix + image_part, headers)
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertEqual(result['depth_mode_actual'], 'mixed')
        self.assertEqual(result['detections'][0]['distance_m'], 3.0)
        compare = b'--x\r\nContent-Disposition: form-data; name="compare_depth"\r\n\r\n1\r\n'
        status, data = self.request('POST', '/api/analyze', prefix + compare + image_part, headers)
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertEqual(result['depth_mode_actual'], 'standard')
        self.assertEqual(result['depth_grid']['values'][0], 2.0)
        large_body = prefix.replace(b'mixed', b'large') + image_part
        status, data = self.request('POST', '/api/analyze', large_body, headers)
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertEqual(result['depth_mode_actual'], 'large')
        self.assertEqual(result['detections'][0]['distance_m'], 4.0)

    def test_open_vocabulary_prompt_and_limits(self):
        _, jpeg = cv2.imencode('.jpg', np.zeros((8, 8, 3), dtype=np.uint8))
        def multipart(prompt):
            return (b'--x\r\nContent-Disposition: form-data; name="detector"\r\n\r\nowl\r\n'
                    b'--x\r\nContent-Disposition: form-data; name="prompts"\r\n\r\n' + prompt.encode() + b'\r\n'
                    b'--x\r\nContent-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
                    b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n--x--\r\n')
        headers = {'Content-Type': 'multipart/form-data; boundary=x'}
        status, data = self.request('POST', '/api/analyze', multipart('tissue box, person'), headers)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['detections'][0]['label'], 'tissue box')
        large_body = multipart('tissue box').replace(b'\r\nowl\r\n', b'\r\nowl_large\r\n')
        status, data = self.request('POST', '/api/analyze', large_body, headers)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['detections'][0]['label'], 'tissue box')
        status, _ = self.request('POST', '/api/analyze', multipart('x' * 129), headers)
        self.assertEqual(status, 400)

    def test_rejects_cross_origin_and_unknown_host(self):
        status, _ = self.request('POST', '/api/analyze', b'', {'Origin': 'http://example.com'})
        self.assertEqual(status, 403)
        status, _ = self.request('GET', '/api/health', headers={'Host': 'example.com'})
        self.assertEqual(status, 403)

    def test_depth_ignores_invalid_values(self):
        depth = np.full((8, 8), 2.0)
        depth[2, 2] = np.nan
        self.assertEqual(target_depth(depth, [0, 0, 8, 8]), 2.0)
        self.assertIsNone(target_depth(depth, [3, 3, 3, 4]))


if __name__ == '__main__':
    unittest.main()
