# AppointmentReferralLink — Design

Date: 2026-10-08
Status: approved for planning

## Purpose

A deterministic linker with a scored residual. Given one referral and the
appointments already known to be for that patient, return one decision per
pair — `:link`, `:reject`, or `:review` — with a structured rule trace and a
score so every link can be explained later. The package does not search a
database, does not persist decisions, and does not resolve patient identity
unless the caller opts in.

Package name, OTP app, and root module stay as scaffolded:
`:appointment_referral_link` / `AppointmentReferralLink`.

## Scope

In scope:

- Five-stage pipeline: patient gate, window gate, hard-conflict gate,
  structured score, text residual + threshold.
- `rule_match` (github: agoodway/rule_match) drives the conflict gate and the
  default scorer, from JSON rulesets shipped in `priv/rules/`.
- `patient_matching` (github: agoodway/patient_matching) provides the optional
  Fellegi–Sunter patient gate.
- Optional Ortex/ONNX tree scorer behind the same scorer behaviour.
- `evaluate/2` with precision, recall, review rate, cross-referral false-link
  rate.

Out of scope (deferred):

- Laya, the Python text service, the stacker. Only the `Score.Text` behaviour
  and its `None` adapter ship now.
- Training of the tree (happens outside Elixir).
- Training of the Fellegi–Sunter model (the caller trains and dumps it with
  `patient_matching`).

## Public API

```elixir
AppointmentReferralLink.link(referral, appointments, opts \\ [])
# => {:ok, [%Decision{}]} | {:error, reason}

AppointmentReferralLink.evaluate(labeled_pairs, opts \\ [])
# => %Report{}
```

`%Decision{}` fields:

- `appointment_id`
- `referral_id`
- `outcome`: `:link | :reject | :review`
- `score`: float or `nil` (nil when a gate rejected)
- `reasons`: list of atoms
- `components`: map holding `identity` probability, `features`,
  `score_rules` fired, `scorer`, and `text` result

Reason atoms:

- `:patient_mismatch`
- `:outside_window`
- `:status_excluded`
- `:already_linked`
- `:laterality_conflict`
- `:specialty_mismatch`
- any reason a site adds through a conflict rule outcome
- `:scorer_error`
- `:text_unavailable`
- `:score` (the threshold decided)

Reasons are atoms only. Detail lives in `components`. Reasons that come from
rule outcomes are mapped to atoms through an allow-list (the known atoms
above plus `conflict_reasons:` from config). An unknown reason string becomes
`:conflict_rule`, and its rule id is recorded in `components.conflict_rules`.
The package never creates atoms from data.

## Data structs

`%Referral{}`:

- `id`, `patient_id`, `issued_on`, `auth_start`, `auth_end`
- `specialty`, `allowed_specialties`, `body_part`
- `laterality` (`:left | :right | :bilateral | nil`)
- `reason`, `icd10`, `referring_provider_id`, `site_id`
- `patient`: map of demographics, optional, used only by the FS gate

`%Appointment{}`:

- `id`, `patient_id`, `starts_on`
- `status` (`:booked | :completed | :cancelled | :no_show`)
- `specialty`, `subspecialty`, `body_part`, `laterality`, `reason`
- `cpt`, `icd10`, `rendering_provider_id`, `site_id`
- `booked_from_referral`, `linked_referral_id`
- `patient`: optional

Codes are strings and dates are `Date`. Both structs are plain data that can
be serialized.

The demographics maps use the `patient_matching` record shape:
`given_name`, `family_name`, `dob`, `sex`, `zip`, `phone`, `street`, and
optionally `ssn` / `mrn` / `source`. The gate supplies `:id`.

## Module layout

```
lib/appointment_referral_link.ex            link/3, evaluate/2
lib/appointment_referral_link/
  referral.ex  appointment.ex  decision.ex  report.ex
  config.ex                                 merge app env + opts; validate
  pipeline.ex                               per-pair stage runner, trace
  gate/patient.ex                           :exact | {:fellegi_sunter, model}
  gate/window.ex                            date window, statuses, already_linked
  gate/conflict.ex                          RuleMatch over feature map
  identity/fellegi_sunter.ex                load model; explain/3; threshold
  laterality.ex                             fill nil laterality from reason text
  ontology.ex                               body-part matching from JSON
  features.ex                               pair -> flat feature map
  score.ex                                  scorer behaviour
  score/rules.ex                            default: weighted RuleMatch rules
  score/tree.ex                             Ortex ONNX, compiled if Ortex loaded
  score/text.ex                             text adapter behaviour
  score/text/none.ex                        identity adapter
  threshold.ex                              score -> outcome
priv/ontology/body_parts.json
priv/rules/conflicts.json
priv/rules/score_weights.json
priv/codes/specialty_cpt.json
```

## Pipeline

For each appointment, against the single referral:

1. **Patient gate.** On failure, reject with `:patient_mismatch` and stop.
2. **Window gate.** On failure, reject with `:outside_window`,
   `:status_excluded`, or `:already_linked` and stop. Every reason that
   applies is collected.
3. **Laterality fill.** Fill missing laterality from the reason text, on each
   side independently.
4. **Features.** Build the flat feature map.
5. **Conflict gate.** `RuleMatch.match/3` with the conflicts ruleset over the
   feature map. Any match rejects the pair, with the reasons from every
   matching rule. Stop.
6. **Score.** The configured scorer returns `{:ok, p}` or `{:error, _}`. On
   error or exception the outcome is `:review` with `:scorer_error`. Stop.
7. **Text residual.** Runs only if `review_low <= p <= review_high`. The
   adapter is called under `Task` with a `text_timeout`. Results:
   - `{:ok, p'}`: p' replaces p (with `None` this is p unchanged)
   - timeout, `{:error, _}`, or an exception: the outcome is `:review` with
     `:text_unavailable`. Stop.
8. **Threshold.** `p >= link_at` gives `:link`. `p < reject_at` gives
   `:reject`. Anything else gives `:review`. The reason is `:score`.

Invariants (covered by property tests):

- `:link` is produced only in step 8.
- Step 8 is reached only for pairs with no gate reasons.
- A text adapter cannot overturn a gate, and cannot produce `:link` when it
  fails.

### Patient gate

- `patient_gate: :exact` (the default) passes when `patient_id` is equal and
  not nil.
- `patient_gate: {:fellegi_sunter, model}`, where `model` is a
  `PatientMatching` model or `{json, config}`. In the second form the gate
  calls `PatientMatching.load/2` once per `link/3` call.
  - The pair passes when `explain/3` gives `probability >= fs_link_at`
    (default 0.95) and the result has no fired guards.
  - Missing `patient` maps fail the gate.
  - The probability is stored in `components.identity` and never reused
    downstream.

### Window gate

The window is `[issued_on - lead_days, window_end + lag_days]`, where:

- `window_end` is `auth_end`, or else `issued_on + default_auth_days`
  (default 90).
- `starts_on` must fall inside the window, inclusive at both ends.

Other rejections:

- A status in `drop_statuses` (default `[:cancelled, :no_show]`) rejects with
  `:status_excluded`.
- A non-nil `linked_referral_id` that differs from `referral.id` rejects with
  `:already_linked`. Deciding whether that other referral is open is the
  caller's job.

### Laterality

Token matching on the lowercase `reason`, splitting on non-letters:

- `rt` / `right` maps to `:right`
- `lt` / `left` maps to `:left`
- `bilateral` / `bilat` / `both` maps to `:bilateral`
- both right and left tokens present maps to `:bilateral`

The fill runs only when the structured field is nil. No other narrative
parsing.

`laterality_match`:

- `:unknown` if either side is nil
- `:agree` if the sides are equal, or either side is `:bilateral`
- `:conflict` for left vs right

### Ontology

`body_parts.json` holds `{"format": 1, "parts": {"knee": {"synonyms":
["knee joint"], "children": ["medial knee", "lateral knee", "patella",
"acl", "meniscus"]}, ...}}`.

- Terms are normalized by trimming, lowercasing, and collapsing whitespace.
- `Ontology.match(a, b)` returns:
  - `:exact`: same canonical part
  - `:related`: one side is a child of the other's canonical part, or both
    are children of the same part
  - `:mismatch`: anything else
  - `:unknown`: either side is nil or the term is not in the ontology
- The ontology loads once per `link/3` call. Extra files from
  `ontology_paths:` merge into it, adding synonyms and children.

### Features

One map per pair. Values are atoms, numbers, booleans, or nil. Missing values
stay nil and are never imputed.

- `days_from_issue`, `days_from_auth_start`, `days_to_auth_end`: integers,
  nil if the source date is nil
- `specialty_match`: `:exact | :allowed | :mismatch`, or nil when either
  specialty is missing
- `subspecialty_match`: from the ontology, comparing the appointment's
  subspecialty with the referral's body part
- `body_part_match`: from the ontology
- `laterality_match`
- `icd_overlap`: the number of the referral's ICD-10 3-character categories
  that appear among the appointment's categories
- `cpt_in_referral_family`: the number of appointment CPT codes inside the
  referral specialty's ranges in `specialty_cpt.json`; nil if the specialty
  has no ranges
- `same_referring_provider`: the referral's `referring_provider_id` equals
  the appointment's `rendering_provider_id`
- `booked_from_referral`, `appointment_status`
- `site_match`: nil when either `site_id` is missing
- `already_linked`: kept as a safety feature
- `laterality_missing`, `body_part_missing`, `specialty_missing`,
  `icd_missing`: booleans

### Conflict ruleset

`priv/rules/conflicts.json` is a `rule_match` ruleset. Each rule has an
outcome `{"reason": "<string>"}`. Shipped rules:

- `laterality_match eq conflict` gives `laterality_conflict`
- `specialty_match eq mismatch` gives `specialty_mismatch`

Missing laterality or specialty never matches, because those features become
nil or `:unknown`. Override with `conflict_rules:`, which takes a path or a
`%RuleMatch.Ruleset{}`.

### Scorers

`AppointmentReferralLink.Score` behaviour:

```elixir
@callback score(features :: map(), opts :: keyword()) :: {:ok, float()} | {:error, term()}
```

**`Score.Rules`** (default)

- Weights come from `priv/rules/score_weights.json`, a `rule_match` ruleset.
  Each rule's outcome is `{"weight": number}`, and an `intercept` sits in the
  ruleset `meta`.
- `p = 1 / (1 + e^-(intercept + Σ weights of matched rules))`.
- The ids of matched rules go into `components.score_rules`.
- The default weights are hand-set to be conservative. Only strong agreement
  across features clears 0.92:
  - exact specialty
  - body part exact or related
  - laterality agrees
  - booked from the referral
  - an ICD overlap
  - within 30 days of issue

  Weak or missing evidence lands in the review band.

**`Score.Tree`**

- Compiled only when `Ortex` is available.
- Options: `model_path` (default `priv/models/linker.onnx`) and
  `columns_path` (default `linker.features.json` next to the model). The
  columns file gives the column order and the one-hot categories.
- Encoding: numbers as is, booleans as 0/1, categoricals one-hot, nil as NaN.
- Runs the model and returns the positive-class probability.
- The model loads lazily and is cached in `:persistent_term` under its path.

**`Score.Text`** behaviour:

```elixir
@callback refine(referral, appointment, features, p :: float(), opts) :: {:ok, float()} | {:error, term()}
```

- `Score.Text.None` returns `{:ok, p}`.

### Configuration

```elixir
config :appointment_referral_link,
  lead_days: 7,
  lag_days: 14,
  default_auth_days: 90,
  drop_statuses: [:cancelled, :no_show],
  link_at: 0.92,
  reject_at: 0.35,
  review_low: nil,          # defaults to reject_at
  review_high: nil,         # defaults to link_at
  patient_gate: :exact,
  fs_link_at: 0.95,
  scorer: AppointmentReferralLink.Score.Rules,
  text_adapter: AppointmentReferralLink.Score.Text.None,
  text_timeout: 2_000,
  ontology_paths: [],
  conflict_rules: nil,      # nil = shipped priv file
  score_rules: nil,
  conflict_reasons: []
```

- Per-call opts override the application env.
- `Config` validation returns `{:error, {:invalid_config, msg}}` when:
  - `reject_at > link_at`
  - the review band falls outside `[0, 1]`
  - day values are negative
  - an FS gate is configured without a model

## Error handling

- `link/3` returns `{:error, reason}` only for invalid input structs, invalid
  config, or a ruleset or ontology file that is missing or malformed.
- Failures inside a single pair (a scorer or text adapter error, an exception,
  a timeout) never abort the batch. Those pairs become `:review` with a
  reason.

## Evaluation

`evaluate(labeled, opts)`:

- `labeled` is a list of `%{referral: r, appointment: a, label: boolean}`,
  grouped by referral id and run through `link/3`.
- Every appointment id across the set is mapped to its true referral ids
  (from rows labeled true), so cross-referral errors can be detected.

`%Report{}` fields:

- `precision`: the share of `:link` decisions labeled true; nil if there are
  no links
- `recall`: the share of true pairs decided `:link`
- `review_rate`: the share of all decisions that were `:review`
- `cross_referral_false_link_rate`: false links whose appointment truly
  belongs to a different referral, divided by all links. 0.0 if there are no
  links.
- `counts`: a confusion map of outcome × label

## Testing (definition of done)

- **Property tests (StreamData).** Generated pairs plus a stub text adapter
  that always returns 0.99 and a stub scorer that returns 0.99. None of these
  ever produce `:link`:
  - laterality conflict (structured or filled from the reason text)
  - failed patient gate (both exact and FS)
  - outside the window
  - excluded status
  - already linked elsewhere
- **Golden pairs.** `test/fixtures/golden.json` holds about 15 de-identified
  pairs with expected outcomes, including the hard negative: same patient,
  same knee and specialty, nearby date, different referral.
- **Evaluation gate.** `evaluate/2` over `test/fixtures/labeled.json` is
  checked against `test/fixtures/baseline.json`. The test fails if precision
  falls below the baseline or the cross-referral false-link rate rises above
  it.
- **Adapter down.** A stub that sleeps past `text_timeout` and a stub that
  raises both give `:review` with `:text_unavailable`.
- **Unit tests:** config validation, laterality, ontology (knee ~ medial
  knee, knee ≁ shoulder, site extension), features (missingness, counts),
  window edges (inclusive), `Score.Rules` (logistic arithmetic, trace).
- **FS gate:** a synthetic `PatientMatching` model trained in test setup;
  the same person passes and a different person rejects.
- **Tree:** tests tagged `:ortex` and excluded by default.

## Dependencies

```elixir
{:rule_match, github: "agoodway/rule_match"},
{:patient_matching, github: "agoodway/patient_matching"},
{:ortex, "~> 0.1", optional: true},
{:stream_data, "~> 1.1", only: :test}
```

- JSON uses Elixir's built-in `JSON` module.
- `rule_match` brings `ecto_sql` at runtime. We use only in-memory rulesets
  and the file adapter, and never start a Repo.
