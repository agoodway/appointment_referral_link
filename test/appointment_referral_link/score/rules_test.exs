defmodule AppointmentReferralLink.Score.RulesTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, CptFamilies, Features, Ontology, Score}

  setup do
    {:ok, c} = Config.build([])
    {:ok, state} = Score.Rules.init(c)
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{state: state, f: fn r, a -> Features.build(r, a, o, cpt) end}
  end

  test "logistic arithmetic" do
    assert Score.Rules.logistic(0) == 0.5
    assert_in_delta Score.Rules.logistic(3.1), 0.9569, 0.0001
  end

  test "strongest profile clears link_at", %{state: s, f: f} do
    assert {:ok, p, %{logit: logit, rules: rules}} =
             Score.Rules.score(f.(referral(), appointment()), s)

    assert_in_delta logit, 3.1, 1.0e-9
    assert p > 0.92

    assert Enum.sort(rules) ==
             ~w(body_part_agree booked_from_referral icd_overlap laterality_agree near_issue specialty_exact)
  end

  test "dropping ICD overlap lands in the review band", %{state: s, f: f} do
    {:ok, p, _} = Score.Rules.score(f.(referral(), appointment(icd10: ["S83.2"])), s)
    assert p > 0.35 and p < 0.92
  end

  test "nil ICD does not count as overlap", %{state: s, f: f} do
    {:ok, _, %{rules: rules}} = Score.Rules.score(f.(referral(), appointment(icd10: [])), s)
    refute "icd_overlap" in rules
  end

  test "body-part mismatch without booking scores below reject_at", %{state: s, f: f} do
    a = appointment(body_part: "shoulder", booked_from_referral: false, icd10: ["M75.100"])
    {:ok, p, _} = Score.Rules.score(f.(referral(), a), s)
    assert p < 0.35
  end

  @tag :tmp_dir
  test "init rejects a ruleset without a numeric intercept", %{tmp_dir: dir} do
    path = Path.join(dir, "w.json")
    File.write!(path, ~s({"format": 1, "rules": []}))
    {:ok, c} = Config.build(score_rules: path)
    assert {:error, {:score_rules, _}} = Score.Rules.init(c)
  end

  @tag :tmp_dir
  test "a rule without a numeric weight is a score error", %{tmp_dir: dir, f: f} do
    path = Path.join(dir, "w.json")

    File.write!(path, ~s({"format": 1, "meta": {"intercept": 0},
      "rules": [{"id": "bad", "conditions": [], "outcome": {"weight": "high"}}]}))

    {:ok, c} = Config.build(score_rules: path)
    {:ok, s} = Score.Rules.init(c)
    assert {:error, {:bad_weight, "bad"}} = Score.Rules.score(f.(referral(), appointment()), s)
  end
end
