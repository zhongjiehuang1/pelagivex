"""Optional local large indoor metric depth candidate.

Values are monocular model estimates, not physical range measurements.
"""
from pathlib import Path

from depth import DepthEstimator


class LargeDepthEstimator(DepthEstimator):
    MODEL_PATH = Path(__file__).resolve().parents[1] / 'model' / 'local-depth-large'

    @property
    def info(self):
        return {
            'name': 'Depth Anything V2 Metric Indoor Large',
            'device': str(self.device),
            'unit': 'estimated meters',
            'domain': 'indoor',
            'license': 'CC-BY-NC-4.0',
            'source': 'https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Large-hf',
        }
