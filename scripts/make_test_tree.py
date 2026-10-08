"""Builds the tiny ONNX fixture used by the :ortex tests. Dev-only.

    python -m venv /tmp/arl && /tmp/arl/bin/pip install scikit-learn skl2onnx numpy
    /tmp/arl/bin/python scripts/make_test_tree.py
"""
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from skl2onnx import to_onnx

OUT = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "models"
COLUMNS = [
    {"name": "days_from_issue"},
    {"name": "booked_from_referral"},
    {"name": "icd_overlap"},
    {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]},
]

rng = np.random.default_rng(1)
n = 400
days = rng.integers(-7, 105, n)
booked = rng.integers(0, 2, n)
icd = rng.integers(0, 3, n)
lat = rng.integers(0, 3, n)
lat_onehot = np.eye(3)[lat]
X = np.column_stack([days, booked, icd, lat_onehot]).astype(np.float32)
y = ((booked == 1) & (lat != 1) & (days < 60)).astype(int)

model = GradientBoostingClassifier(n_estimators=20, max_depth=2, random_state=1).fit(X, y)
onx = to_onnx(model, X[:1], options={id(model): {"zipmap": False}}, target_opset=17)

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "linker.onnx").write_bytes(onx.SerializeToString())
(OUT / "linker.features.json").write_text(json.dumps({"format": 1, "columns": COLUMNS}, indent=2) + "\n")
print(f"wrote {OUT}")
