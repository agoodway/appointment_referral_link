# AppointmentReferralLink

Links appointments to referrals. Given one referral and the appointments
already known to be for that patient, each pair gets `:link`, `:reject`,
or `:review`, with structured reasons and a score. Callers persist
decisions; this package does not search a database or store anything.

```elixir
{:ok, decisions} = AppointmentReferralLink.link(referral, appointments)
report = AppointmentReferralLink.evaluate(labeled_pairs)
```

## Pipeline

1. **Patient gate:** exact `patient_id` by default, or
   `patient_gate: {:fellegi_sunter, model}` using a model trained with
   `patient_matching`.
2. **Window gate:** `[issued_on - lead_days, (auth_end || issued_on + default_auth_days) + lag_days]`,
   dropped statuses, and appointments already linked to another referral.
3. **Conflict gate:** a `rule_match` ruleset over pair features
   (`priv/rules/conflicts.json`): laterality conflict, specialty
   mismatch, plus any site rules.
4. **Score:** `Score.Rules` (weighted `rule_match` rules,
   `priv/rules/score_weights.json`) by default, or `Score.Tree` (ONNX via
   the optional `:ortex` dep).
5. **Text residual and threshold:** pairs in the review band go to the
   `text_adapter` (default `Score.Text.None`). A failing adapter sends the
   pair to `:review`. `link_at` and `reject_at` decide the outcome.

Gates only reject. Only the final threshold produces `:link`.

## Configuration

```elixir
config :appointment_referral_link,
  lead_days: 7,
  lag_days: 14,
  link_at: 0.92,
  reject_at: 0.35,
  text_adapter: AppointmentReferralLink.Score.Text.None
```

Every key can be overridden per call. See `AppointmentReferralLink.Config`.
Sites extend the data with `ontology_paths:`, `conflict_rules:` (plus
`conflict_reasons:` for new reason atoms), `score_rules:`, and
`cpt_families:`.

## Tree model

Train outside Elixir on adjudicated pairs, including hard negatives
(same patient, same body part or specialty, nearby date, different
referral). Export with `skl2onnx` (`zipmap: False`) to
`priv/models/linker.onnx`, and put `linker.features.json` next to it to
give the column order. Add `{:ortex, "~> 0.1.10"}` to your app and set
`scorer: AppointmentReferralLink.Score.Tree`.

## Tests

```sh
mix test                    # :ortex tests excluded
mix test --include ortex    # needs test/fixtures/models (scripts/make_test_tree.py)
```
