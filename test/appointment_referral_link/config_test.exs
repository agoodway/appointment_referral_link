defmodule AppointmentReferralLink.ConfigTest do
  use ExUnit.Case, async: false

  alias AppointmentReferralLink.Config

  test "defaults are conservative and the review band follows the thresholds" do
    assert {:ok, c} = Config.build([])
    assert c.lead_days == 7
    assert c.lag_days == 14
    assert c.default_auth_days == 90
    assert c.drop_statuses == [:cancelled, :no_show]
    assert c.link_at == 0.92
    assert c.reject_at == 0.35
    assert c.review_low == 0.35
    assert c.review_high == 0.92
    assert c.patient_gate == :exact
    assert c.scorer == AppointmentReferralLink.Score.Rules
    assert c.text_adapter == AppointmentReferralLink.Score.Text.None
  end

  test "per-call options override application env" do
    Application.put_env(:appointment_referral_link, :lead_days, 3)
    on_exit(fn -> Application.delete_env(:appointment_referral_link, :lead_days) end)

    assert {:ok, %{lead_days: 3}} = Config.build([])
    assert {:ok, %{lead_days: 5}} = Config.build(lead_days: 5)
  end

  test "rejects unknown options" do
    assert {:error, {:invalid_config, msg}} = Config.build(lead_dayz: 3)
    assert msg =~ "lead_dayz"
  end

  test "rejects reject_at above link_at" do
    assert {:error, {:invalid_config, _}} = Config.build(link_at: 0.5, reject_at: 0.6)
  end

  test "rejects probabilities outside [0, 1]" do
    assert {:error, {:invalid_config, _}} = Config.build(link_at: 1.5)
    assert {:error, {:invalid_config, _}} = Config.build(review_low: -0.1)
  end

  test "rejects an inverted review band" do
    assert {:error, {:invalid_config, _}} = Config.build(review_low: 0.8, review_high: 0.5)
  end

  test "rejects negative day windows" do
    assert {:error, {:invalid_config, _}} = Config.build(lag_days: -1)
  end

  test "rejects a Fellegi–Sunter gate without a model" do
    assert {:error, {:invalid_config, _}} = Config.build(patient_gate: {:fellegi_sunter, nil})
    assert {:error, {:invalid_config, _}} = Config.build(patient_gate: :fuzzy)
  end

  test "rejects non-atom conflict reasons" do
    assert {:error, {:invalid_config, _}} = Config.build(conflict_reasons: ["x"])
  end

  describe "module and path options are type-checked" do
    test "scorer must be a module implementing the scorer behaviour" do
      assert {:error, {:invalid_config, _}} = Config.build(scorer: "x")
      assert {:error, {:invalid_config, _}} = Config.build(scorer: Enum)
      assert {:error, {:invalid_config, _}} = Config.build(scorer: NoSuchModule)
    end

    test "text_adapter must be a module implementing refine/5" do
      assert {:error, {:invalid_config, _}} = Config.build(text_adapter: nil)
      assert {:error, {:invalid_config, _}} = Config.build(text_adapter: Enum)
    end

    test "ontology_paths must be a list of strings" do
      assert {:error, {:invalid_config, _}} = Config.build(ontology_paths: "x.json")
      assert {:error, {:invalid_config, _}} = Config.build(ontology_paths: [:x])
    end

    test "valid modules and paths pass" do
      assert {:ok, _} =
               Config.build(
                 scorer: AppointmentReferralLink.Stubs.HighScorer,
                 text_adapter: AppointmentReferralLink.Stubs.HighText,
                 ontology_paths: ["a.json"]
               )
    end
  end
end
