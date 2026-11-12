"""Analytic, synthetic counterexamples; not a camera experiment or a novelty claim.

Run: python3 scripts/pair_identifiability_probe.py
Angles are normalized image coordinates; translations are metres. Known rotation,
constant depths within the probe and persistent surface points are toy assumptions.
"""
import json
import math


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def nuisance_basis(times, degree):
    basis = []
    for power in range(degree + 1):
        vector = [t ** power for t in times]
        for unit in basis:
            coefficient = dot(vector, unit)
            vector = [v - coefficient * u for v, u in zip(vector, unit)]
        norm = math.sqrt(dot(vector, vector))
        if norm > 1e-12:
            basis.append([v / norm for v in vector])
    return basis


def residualize(vector, basis):
    result = vector[:]
    for unit in basis:
        coefficient = dot(vector, unit)
        result = [v - coefficient * u for v, u in zip(result, unit)]
    return result


def infer(times, camera, separation, degree, declared_error):
    basis = nuisance_basis(times, degree)
    q = residualize(camera, basis)
    energy = dot(q, q)
    if energy < 1e-16:
        return {"status": "unidentifiable", "projected_pose_energy": energy}
    estimate = -dot(q, separation) / energy
    radius = declared_error * sum(abs(v) for v in q) / energy
    interval = [estimate - radius, estimate + radius]
    residual = residualize([y + c * estimate for y, c in zip(separation, camera)], basis)
    return {
        "status": "A_closer" if interval[0] > 0 else "B_closer" if interval[1] < 0 else "abstain",
        "estimated_inverse_depth_contrast": estimate,
        "interval_under_declared_bound": interval,
        "fit_rms": math.sqrt(dot(residual, residual) / len(times)),
        "projected_pose_energy": energy,
    }


def main():
    times = [i / 4 - 1 for i in range(9)]
    paths = {
        "one_way": [0.03 * (t + 1) for t in times],
        "one_return": [0.03 * (1 - abs(t)) for t in times],
        "alternating": [0, 0.0075, 0, -0.0075, 0, 0.0075, 0, -0.0075, 0],
    }
    theta = 0.5
    rows = []
    for name, camera in paths.items():
        travel = sum(abs(b - a) for a, b in zip(camera, camera[1:]))
        for degree in (1, 2):
            # Smooth unknown target motion lies inside the stated nuisance class.
            motion = [0.1 + 0.03 * t + (0.02 * t * t if degree == 2 else 0) for t in times]
            clean = [m - theta * c for m, c in zip(motion, camera)]
            for error in (0.0002, 0.01):
                rows.append({
                    "path": name, "travel_metres": travel, "nuisance_degree": degree,
                    "scenario": "within_stated_motion_class", "true_contrast": theta,
                    "declared_error_bound": error,
                    **infer(times, camera, clean, degree, error),
                })
            # A target motion term correlated with camera motion can exactly fake the
            # opposite order, while preserving zero model residual. No residual gate
            # can validate the external error bound in this construction.
            deceptive = [y + c for y, c in zip(clean, camera)]
            rows.append({
                "path": name, "travel_metres": travel, "nuisance_degree": degree,
                "scenario": "camera_correlated_motion_violates_error_bound",
                "true_contrast": theta, "declared_error_bound": 0.0002,
                **infer(times, camera, deceptive, degree, 0.0002),
            })
    print(json.dumps({
        "type": "analytic synthetic identifiability probe; no learned model or real video",
        "equation": "y = polynomial target motion - camera_translation * inverse_depth_contrast + error",
        "rows": rows,
    }, indent=2))


if __name__ == "__main__":
    main()
