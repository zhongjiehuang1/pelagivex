"""Depth statistics for the visible interior of an instance mask."""
import numpy as np
import cv2


def instance_depth(depth, prototypes, coefficients, box, input_size):
    if depth.ndim != 2 or prototypes.ndim != 3 or len(coefficients) != prototypes.shape[0]:
        return None
    dh, dw = depth.shape
    _, ph, pw = prototypes.shape
    if min(dh, dw, ph, pw) <= 0 or input_size <= 0:
        return None
    box = np.asarray(box, dtype=np.float64)
    if box.shape != (4,) or not np.isfinite(box).all() or box[2] <= box[0] or box[3] <= box[1]:
        return None
    scale = min(input_size / dw, input_size / dh)
    px = (input_size - dw * scale) / 2
    py = (input_size - dh * scale) / 2
    x = ((np.arange(pw, dtype=np.float32) + .5) * input_size / pw - px) / scale
    y = ((np.arange(ph, dtype=np.float32) + .5) * input_size / ph - py) / scale
    gx, gy = np.meshgrid(x, y)
    # The original detector boxes are normalized to the uncropped source frame.
    x1, y1, x2, y2 = box * [dw, dh, dw, dh]
    inside = (gx >= x1) & (gx < x2) & (gy >= y1) & (gy < y2)
    inside &= (gx >= 0) & (gx < dw) & (gy >= 0) & (gy < dh)
    coeff = np.asarray(coefficients, dtype=np.float32)
    if not np.isfinite(coeff).all():
        return None
    mask = np.tensordot(coeff, prototypes.astype(np.float32, copy=False), axes=(0, 0)) > 0
    mask &= inside
    # Erode only when a usable interior remains; thin/small objects keep their mask.
    eroded = cv2.erode(mask.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    if eroded.sum() >= 10:
        mask = eroded
    sampled = cv2.remap(depth.astype(np.float32, copy=False), gx, gy, cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_CONSTANT, borderValue=float('nan'))
    values = sampled[mask & np.isfinite(sampled) & (sampled > 0)]
    return float(np.median(values)) if values.size >= 5 else None
