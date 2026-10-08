# Training the tree model

`AppointmentReferralLink.Score.Tree` scores pairs with a gradient-boosted
tree stored as an ONNX file and run through
[Ortex](https://hex.pm/packages/ortex). No model ships with the package.
This guide covers how to train one, check it, and switch it on.

Until you have a model, the default scorer `Score.Rules` (hand-set
weights in `priv/rules/score_weights.json`) keeps working. You don't
need a tree to use the package.

Training happens in Python. At runtime, Elixir only loads the exported
file.

```
labeled pairs ──► Elixir: export feature rows ──► train.jsonl
                                                     │
                     Python: train + export ONNX ◄───┘
                                │
     linker.onnx + linker.features.json + parity.jsonl
                                │
     Elixir: parity check ──► threshold sweep ──► scorer: Score.Tree
```

The commands below were run end to end on synthetic data with
lightgbm 4.7.0, onnxmltools 1.16.0, onnx 1.23.2, scikit-learn 1.9.1,
Python 3.14 and Elixir 1.19.

---

## 1. Collect labeled pairs

Each training example is one referral–appointment pair with a label
that a reviewer has confirmed:

```elixir
%{referral: %Referral{}, appointment: %Appointment{}, label: true | false}
```

- **Positives** are links a reviewer confirmed. Don't use links you
  inferred from `booked_from_referral` alone.
- **Hard negatives are required.** These are pairs with the same
  patient, the same body part or specialty, and a nearby date, but a
  *different* referral. They're the mistakes that matter most: the
  cross-referral false link. Build them by pairing each referral with
  the patient's appointments that a reviewer assigned to *another*
  referral.
- **Ordinary negatives** are the patient's other appointments that a
  reviewer says don't belong to the referral.
- **Spread the data out.** Include many referrals and patients, and
  ideally several sites and months. The training script splits by
  referral, so it needs many referral ids.
- **Hold out a separate set** for choosing thresholds in step 5. Prefer
  a later time period than the training data, so the check resembles
  production.

The `label` is about the *pair*, not about patient identity. Don't
feed Fellegi–Sunter identity scores into the tree. The patient gate
settles identity before scoring.

## 2. Export feature rows from Elixir

Use the package's own `Features.build/4`, through `link/3`, so the
features you train on are exactly the ones scored at runtime.

Pairs rejected by the patient, window or conflict checks are **skipped**.
The tree never sees those pairs in production, so it shouldn't learn
from them. A decision reached the scorer exactly when its `components`
has a `:scorer` key.

Save as `scripts/export_training_rows.exs` (or anywhere in your app):

```elixir
defmodule TrainingExport do
  @moduledoc false
  # Writes one JSON line per labeled pair that reaches the scorer.
  # Pairs rejected by the patient, window, or conflict gates are skipped:
  # the tree never sees them at runtime, so it should not train on them.
  def write!(labeled, path) do
    rows =
      Enum.flat_map(labeled, fn %{referral: r, appointment: a, label: label} ->
        {:ok, [d]} = AppointmentReferralLink.link(r, [a])

        if Map.has_key?(d.components, :scorer) do
          features = AppointmentReferralLink.Features.to_candidate(d.components.features)

          [
            JSON.encode!(%{
              referral_id: r.id,
              appointment_id: a.id,
              label: label,
              features: features
            })
          ]
        else
          []
        end
      end)

    File.write!(path, Enum.join(rows, "\n") <> "\n")
    IO.puts("wrote #{length(rows)} of #{length(labeled)} pairs to #{path}")
  end
end
```

Load your adjudicated pairs into that shape however suits your data
store, then call:

```elixir
TrainingExport.write!(labeled, "train.jsonl")
```

Run the export with the same configuration you use in production
(`lead_days`, `lag_days`, `drop_statuses`, ontology and conflict rule
files). Otherwise the set of pairs that "survive the gates" won't
match.

Each line looks like this:

```json
{"label":true,"referral_id":"ref_1","appointment_id":"a3","features":{"days_from_issue":21,"specialty_match":"exact","laterality_match":"agree","icd_overlap":0,"booked_from_referral":true, "...": "..."}}
```

## 3. Train and export ONNX

Set up an isolated Python environment:

```sh
python -m venv .venv-train
.venv-train/bin/pip install lightgbm onnxmltools onnx scikit-learn numpy packaging
```

Save as `scripts/train_tree.py`:

```python
"""Train the linker tree from exported rows and write ONNX + column spec.

Usage: python train_tree.py train.jsonl OUT_DIR
"""
import json
import sys
from pathlib import Path

import numpy as np
from lightgbm import LGBMClassifier
from onnxmltools import convert_lightgbm
from onnxmltools.convert.common.data_types import FloatTensorType
from sklearn.metrics import precision_score, recall_score
from sklearn.model_selection import GroupShuffleSplit

# Column order is the model's contract with Elixir. It is written to
# linker.features.json; Score.Tree.Encoder rebuilds rows in this order.
COLUMNS = [
    {"name": "days_from_issue"},
    {"name": "days_from_auth_start"},
    {"name": "days_to_auth_end"},
    {"name": "specialty_match", "one_hot": ["exact", "allowed", "mismatch"]},
    {"name": "subspecialty_match", "one_hot": ["exact", "related", "mismatch", "unknown"]},
    {"name": "body_part_match", "one_hot": ["exact", "related", "mismatch", "unknown"]},
    {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]},
    {"name": "icd_overlap"},
    {"name": "cpt_in_referral_family"},
    {"name": "same_referring_provider"},
    {"name": "booked_from_referral"},
    {"name": "appointment_status", "one_hot": ["booked", "completed", "cancelled", "no_show"]},
    {"name": "site_match"},
    {"name": "already_linked"},
    {"name": "laterality_missing"},
    {"name": "body_part_missing"},
    {"name": "specialty_missing"},
    {"name": "icd_missing"},
]

NAN = float("nan")


def numeric(value):
    # Must match Score.Tree.Encoder: nil -> NaN, booleans -> 1/0.
    if value is None:
        return NAN
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return NAN


def encode(features):
    row = []
    for col in COLUMNS:
        value = features.get(col["name"])
        if "one_hot" in col:
            if value is None:
                row.extend([NAN] * len(col["one_hot"]))
            else:
                row.extend(1.0 if value == cat else 0.0 for cat in col["one_hot"])
        else:
            row.append(numeric(value))
    return row


def main(rows_path, out_dir):
    rows = [json.loads(line) for line in Path(rows_path).read_text().splitlines() if line.strip()]
    X = np.array([encode(r["features"]) for r in rows], dtype=np.float32)
    y = np.array([1 if r["label"] else 0 for r in rows])
    groups = np.array([r["referral_id"] for r in rows])

    # Split by referral so one referral's pairs never land in both sets.
    train_idx, test_idx = next(GroupShuffleSplit(test_size=0.2, random_state=1).split(X, y, groups))

    # LightGBM handles NaN natively, so missing features stay missing.
    model = LGBMClassifier(
        n_estimators=200, learning_rate=0.05, num_leaves=15, min_child_samples=10,
        random_state=1, verbose=-1,
    )
    model.fit(X[train_idx], y[train_idx])

    p = model.predict_proba(X[test_idx])[:, 1]
    for t in (0.80, 0.90, 0.92, 0.95):
        pred = p >= t
        print(f"held-out @ {t:.2f}: precision={precision_score(y[test_idx], pred, zero_division=0):.3f} "
              f"recall={recall_score(y[test_idx], pred, zero_division=0):.3f}")

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    onx = convert_lightgbm(
        model,
        initial_types=[("input", FloatTensorType([None, X.shape[1]]))],
        zipmap=False,
        target_opset=15,
    )
    (out / "linker.onnx").write_bytes(onx.SerializeToString())
    (out / "linker.features.json").write_text(json.dumps({"format": 1, "columns": COLUMNS}, indent=2) + "\n")

    # Parity rows: Elixir must reproduce these probabilities from the same features.
    sample = test_idx[:50]
    with (out / "parity.jsonl").open("w") as f:
        for i, prob in zip(sample, model.predict_proba(X[sample])[:, 1]):
            f.write(json.dumps({"features": rows[i]["features"], "p": float(prob)}) + "\n")
    print(f"wrote {out}/linker.onnx, linker.features.json, parity.jsonl")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
```

Run it:

```sh
.venv-train/bin/python scripts/train_tree.py train.jsonl out/
```

It prints held-out precision and recall at a few thresholds, then
writes three files:

| File | Purpose |
|---|---|
| `linker.onnx` | The model. Input: float32 `{n, 31}` (31 columns after one-hot). Outputs: `label`, `probabilities` `{n, 2}`. |
| `linker.features.json` | The column order and one-hot categories, read by `Score.Tree.Encoder`. |
| `parity.jsonl` | 50 held-out rows with Python's probability, used in step 4. Not deployed. |

### Rules the training script must follow

- **The encoding must match `Score.Tree.Encoder` exactly:**
  - numbers become floats
  - `true`/`false` become `1.0`/`0.0`
  - a nil numeric becomes NaN
  - a nil categorical sets *every* one-hot column in its group to NaN
  - an unexpected category sets every column in its group to 0

  If you change one side, change the other. The parity check in step 4
  catches drift.
- **Use only names from `Features.names/0`.** The Elixir encoder rejects
  unknown column names at `init/1`. You may leave columns out, but each
  column must be the exact feature name.
- **Keep missing values as NaN; don't impute them.** LightGBM learns
  which way missing values should go at each split.
- **Export with `zipmap=False`.** `Score.Tree` reads the second output
  as a plain `{n, 2}` tensor and takes column 1 as the link
  probability.

### Why LightGBM rather than scikit-learn

`skl2onnx` 1.20 fails to convert `HistGradientBoostingClassifier` (the
scikit-learn tree that handles NaN) with recent `onnx` releases (`TypeError:
Field onnx.AttributeProto.ints: Expected an int, got a boolean`).
`GradientBoostingClassifier` converts, but it can't train on NaN, so
missing features would have to be imputed. LightGBM with `onnxmltools`
avoids both problems. `onnxmltools` 1.16 supports opset 15 at most,
hence `target_opset=15`.

## 4. Check Elixir/Python parity

Before trusting the model, confirm that Elixir produces the same
probabilities as Python for the same features. This catches encoder
drift, column-order mistakes, and converter bugs.

Save as `scripts/tree_parity.exs`:

```elixir
# Checks that Elixir scores the parity rows exactly as Python did.
[model_dir] = System.argv()
alias AppointmentReferralLink.{Config, Features, Score}

Code.ensure_loaded!(Features)

{:ok, config} =
  Config.build(scorer: Score.Tree, tree_model_path: Path.join(model_dir, "linker.onnx"))

{:ok, state} = Score.Tree.init(config)

diffs =
  model_dir
  |> Path.join("parity.jsonl")
  |> File.stream!()
  |> Enum.map(fn line ->
    %{"features" => features, "p" => expected} = JSON.decode!(line)
    features = Map.new(features, fn {k, v} -> {String.to_existing_atom(k), v} end)
    {:ok, p, _} = Score.Tree.score(features, state)
    abs(p - expected)
  end)

max = Enum.max(diffs)
IO.puts("parity rows: #{length(diffs)}, max |elixir - python| = #{max}")
if max > 1.0e-4, do: System.halt(1)
```

```sh
mix run scripts/tree_parity.exs out/
# parity rows: 50, max |elixir - python| = 8.23e-08
```

The difference should be around 1e-7, which is float32 rounding. Any
difference above 1e-4 means the two sides encode features differently.
Fix that before going further.

## 5. Choose thresholds on held-out data

`link_at` and `reject_at` are set per deployment, **precision first**.
Run `evaluate/2` with the tree on the held-out set from step 1. Don't
use the pairs you trained on.

```elixir
model = "out/linker.onnx"

for link_at <- [0.80, 0.90, 0.92, 0.95, 0.98] do
  r =
    AppointmentReferralLink.evaluate(held_out,
      scorer: AppointmentReferralLink.Score.Tree,
      tree_model_path: model,
      link_at: link_at
    )

  IO.puts(
    "link_at=#{link_at} precision=#{inspect(r.precision)} recall=#{inspect(r.recall)} " <>
      "review_rate=#{inspect(r.review_rate)} cross=#{inspect(r.cross_referral_false_link_rate)}"
  )
end
```

To choose:

1. Rule out any `link_at` where `cross_referral_false_link_rate` is above
   zero, or above whatever your reviewers can tolerate. These are links
   to the wrong referral.
2. Among the rest, pick the lowest `link_at` that meets your precision
   target. That maximizes recall without giving up precision.
3. Set `reject_at` by sweeping the low end the same way. Pairs between
   `reject_at` and `link_at` go to reviewers, so `review_rate` is your
   review workload.
4. Pin the result in your CI baseline: copy `test/fixtures/baseline.json`
   and point the evaluation-gate test at your held-out set, so a
   retrained model that's worse fails the build.

## 6. Deploy

1. Copy `linker.onnx` and `linker.features.json` into your app's
   `priv/models/`, or anywhere you like, and set `tree_model_path` to
   that location. The column file must sit next to the model unless you
   set `tree_columns_path`.
2. Add Ortex to your app; it's optional in this package:

   ```elixir
   {:ortex, "~> 0.1.10"}
   ```

3. Configure:

   ```elixir
   config :appointment_referral_link,
     scorer: AppointmentReferralLink.Score.Tree,
     tree_model_path: "/path/to/linker.onnx",
     link_at: 0.95,   # from step 5
     reject_at: 0.30  # from step 5
   ```

4. **Version the model next to the ontology and rule files** it was
   trained with. A model trained against one ontology or set of
   conflict rules sees different features under another.

The loaded model is cached per path and reloaded when the file's
modification time or size changes, so replacing the file in place takes
effect on the next `link/3` call. Writing to a new versioned path,
e.g. `linker-2026-10.onnx`, and changing `tree_model_path` makes
rollback easier.

## 7. Retraining

Retrain when any of these change, then repeat steps 2–5:

- The ontology (`body_parts.json`), the conflict rules, or the CPT
  family table. These change the features.
- The window settings (`lead_days`, `lag_days`, `drop_statuses`). These
  change which pairs reach the tree.
- Reviewer decisions pile up, especially on pairs that went to review.

Pairs in the review band are the most informative new labels. Prioritize
getting those adjudicated.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `{:invalid_config, "scorer must be a module implementing ..."}` | Ortex isn't in your app's deps, so `Score.Tree` isn't compiled. |
| `{:error, {:tree_columns, path, {:unknown_feature, name}}}` | A column in `linker.features.json` isn't a name from `Features.names/0`. |
| `{:error, {:tree_model, path, :enoent}}` | `tree_model_path` is wrong, or `linker.features.json` isn't next to it. |
| Every pair goes to `:review` with `:scorer_error` | The model's input width doesn't match the column file (`components.score_error` has the detail). Re-export both files together. |
| Parity difference above 1e-4 | The Python `encode/1` and `Score.Tree.Encoder` disagree. Check NaN handling and one-hot order. |
| `ValueError: ... the resulting train set will be empty` | All rows share one `referral_id`; the split needs many referrals. |
| `target_opset 17 is higher than ... (15)` | `onnxmltools` supports opset 15 at most. Keep `target_opset=15`. |
