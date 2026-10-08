defmodule AppointmentReferralLink.Score.TreeTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, CptFamilies, Features, Ontology, Score.Tree.Encoder}

  @models Path.expand("../../fixtures/models", __DIR__)

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{f: fn r, a -> Features.build(r, a, o, cpt) end}
  end

  @tag :tmp_dir
  test "encodes numerics, booleans, one-hot, and nil as NaN", %{tmp_dir: dir, f: f} do
    path = Path.join(dir, "cols.json")

    File.write!(path, ~s({"format": 1, "columns": [
      {"name": "days_from_issue"},
      {"name": "booked_from_referral"},
      {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]},
      {"name": "icd_overlap"},
      {"name": "specialty_match", "one_hot": ["exact", "allowed", "mismatch"]}]}))

    {:ok, cols} = Encoder.load(path)
    features = f.(referral(), appointment(icd10: [], specialty: nil))

    assert Encoder.encode(features, cols) ==
             [17.0, 1.0, 1.0, 0.0, 0.0, :nan, :nan, :nan, :nan]
  end

  @tag :tmp_dir
  test "rejects unknown column names", %{tmp_dir: dir} do
    path = Path.join(dir, "cols.json")
    File.write!(path, ~s({"format": 1, "columns": [{"name": "days_from_issu"}]}))

    assert {:error, {:tree_columns, ^path, {:unknown_feature, "days_from_issu"}}} =
             Encoder.load(path)
  end

  @tag :ortex
  test "scores with the fixture model", %{f: f} do
    {:ok, c} =
      Config.build(
        scorer: AppointmentReferralLink.Score.Tree,
        tree_model_path: Path.join(@models, "linker.onnx")
      )

    {:ok, state} = AppointmentReferralLink.Score.Tree.init(c)

    {:ok, booked, _} =
      AppointmentReferralLink.Score.Tree.score(f.(referral(), appointment()), state)

    {:ok, unbooked, _} =
      AppointmentReferralLink.Score.Tree.score(
        f.(referral(), appointment(booked_from_referral: false)),
        state
      )

    assert booked >= 0.0 and booked <= 1.0
    assert booked > unbooked

    assert {:ok, [d]} =
             AppointmentReferralLink.link(referral(), [appointment()],
               scorer: AppointmentReferralLink.Score.Tree,
               tree_model_path: Path.join(@models, "linker.onnx")
             )

    assert d.outcome in [:link, :review, :reject]
  end

  @tag :ortex
  test "a missing model is an init error" do
    {:ok, c} =
      Config.build(
        tree_model_path: "/nope/linker.onnx",
        tree_columns_path: Path.join(@models, "linker.features.json")
      )

    assert {:error, {:tree_model, "/nope/linker.onnx", _}} =
             AppointmentReferralLink.Score.Tree.init(c)
  end

  @tag :ortex
  @tag :tmp_dir
  test "a model replaced at the same path is reloaded, not served from cache", %{
    tmp_dir: dir,
    f: f
  } do
    model = Path.join(dir, "linker.onnx")
    File.cp!(Path.join(@models, "linker.onnx"), model)
    File.cp!(Path.join(@models, "linker.features.json"), Path.join(dir, "linker.features.json"))

    {:ok, c} = Config.build(tree_model_path: model)
    assert {:ok, state} = AppointmentReferralLink.Score.Tree.init(c)

    assert {:ok, _, _} =
             AppointmentReferralLink.Score.Tree.score(f.(referral(), appointment()), state)

    File.write!(model, "not an onnx model")
    File.touch!(model, System.os_time(:second) + 10)

    assert {:error, {:tree_model, ^model, _}} = AppointmentReferralLink.Score.Tree.init(c)
  end
end
