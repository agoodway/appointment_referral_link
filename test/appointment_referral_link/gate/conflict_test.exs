defmodule AppointmentReferralLink.Gate.ConflictTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{CptFamilies, Features, Gate.Conflict, Ontology}

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    {:ok, rules} = Conflict.load(nil)
    features = fn r, a -> Features.build(r, a, o, cpt) end
    %{features: features, rules: rules}
  end

  test "clean pair has no conflicts", %{features: f, rules: rules} do
    assert {[], []} = Conflict.check(f.(referral(), appointment()), rules, [])
  end

  test "laterality conflict", %{features: f, rules: rules} do
    assert {[:laterality_conflict], ["laterality_conflict"]} =
             Conflict.check(f.(referral(), appointment(laterality: :left)), rules, [])
  end

  test "specialty mismatch and laterality together", %{features: f, rules: rules} do
    {reasons, _} =
      Conflict.check(
        f.(referral(), appointment(laterality: :left, specialty: "cardiology")),
        rules,
        []
      )

    assert Enum.sort(reasons) == [:laterality_conflict, :specialty_mismatch]
  end

  test "missing laterality or specialty is not a conflict", %{features: f, rules: rules} do
    assert {[], _} =
             Conflict.check(
               f.(referral(laterality: nil), appointment(laterality: :left)),
               rules,
               []
             )

    assert {[], _} = Conflict.check(f.(referral(), appointment(specialty: nil)), rules, [])
  end

  test "site rules map known reasons, and unknown reasons become :conflict_rule", %{features: f} do
    site =
      RuleMatch.Ruleset.from_json(~s({"format": 1, "rules": [
        {"id": "unbooked_mismatch", "conditions": [
          {"op": "eq", "field": "booked_from_referral", "value": false},
          {"op": "eq", "field": "body_part_match", "value": "mismatch"}],
         "outcome": {"reason": "unbooked_body_mismatch"}},
        {"id": "odd", "conditions": [{"op": "eq", "field": "booked_from_referral", "value": false}],
         "outcome": {"reason": "never_seen_atom_xyz"}}]}))

    {:ok, site} = site
    pair = f.(referral(), appointment(booked_from_referral: false, body_part: "shoulder"))

    assert {reasons, ids} = Conflict.check(pair, site, [:unbooked_body_mismatch])
    assert Enum.sort(reasons) == [:conflict_rule, :unbooked_body_mismatch]
    assert Enum.sort(ids) == ["odd", "unbooked_mismatch"]
  end

  test "load/1 reports a missing file" do
    assert {:error, {:ruleset, "/nope.json", :enoent}} = Conflict.load("/nope.json")
  end
end
