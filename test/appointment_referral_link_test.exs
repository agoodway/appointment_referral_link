defmodule AppointmentReferralLinkTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Decision, Stubs}

  @band [review_low: 0.0, review_high: 1.0]

  test "clean pair links with a trace" do
    assert {:ok, [%Decision{} = d]} = AppointmentReferralLink.link(referral(), [appointment()])
    assert d.outcome == :link
    assert d.reasons == [:score]
    assert d.appointment_id == "appt_1"
    assert d.referral_id == "ref_1"
    assert d.score > 0.92
    assert d.components.features.laterality_match == :agree
    assert d.components.scorer == AppointmentReferralLink.Score.Rules
    assert "booked_from_referral" in d.components.score.rules
  end

  test "one decision per appointment, in input order" do
    appts = [
      appointment(id: "a"),
      appointment(id: "b", laterality: :left),
      appointment(id: "c", patient_id: "x")
    ]

    {:ok, decisions} = AppointmentReferralLink.link(referral(), appts)

    assert Enum.map(decisions, &{&1.appointment_id, &1.outcome, &1.reasons}) == [
             {"a", :link, [:score]},
             {"b", :reject, [:laterality_conflict]},
             {"c", :reject, [:patient_mismatch]}
           ]
  end

  test "gate rejections carry no score" do
    {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment(status: :cancelled)])
    assert d.outcome == :reject
    assert d.score == nil
    assert d.reasons == [:status_excluded]
  end

  test "laterality filled from reason text triggers the conflict gate" do
    {:ok, [d]} =
      AppointmentReferralLink.link(referral(), [appointment(laterality: nil, reason: "lt knee")])

    assert d.reasons == [:laterality_conflict]
    assert d.components.features.laterality_match == :conflict
  end

  test "empty appointment list" do
    assert {:ok, []} = AppointmentReferralLink.link(referral(), [])
  end

  test "invalid input" do
    assert {:error, {:invalid_input, _}} = AppointmentReferralLink.link(referral(), [%{id: "x"}])
    assert {:error, {:invalid_input, _}} = AppointmentReferralLink.link(%{id: "r"}, [])
  end

  test "invalid config and missing data files are errors" do
    assert {:error, {:invalid_config, _}} =
             AppointmentReferralLink.link(referral(), [], reject_at: 0.99)

    assert {:error, {:ruleset, _, _}} =
             AppointmentReferralLink.link(referral(), [], conflict_rules: "/nope.json")

    assert {:error, {:ontology, _, _}} =
             AppointmentReferralLink.link(referral(), [], ontology_paths: ["/nope.json"])
  end

  describe "scorer failures go to review, never link" do
    for scorer <- [Stubs.RaisingScorer, Stubs.BadScorer, Stubs.IntScorer] do
      test "#{inspect(scorer)}" do
        {:ok, [d]} =
          AppointmentReferralLink.link(referral(), [appointment()], scorer: unquote(scorer))

        assert d.outcome == :review
        assert d.reasons == [:scorer_error]
        assert d.score == nil
      end
    end
  end

  describe "text adapter" do
    test "is skipped outside the band" do
      {:ok, [d]} =
        AppointmentReferralLink.link(referral(), [appointment()], text_adapter: Stubs.LowText)

      assert d.outcome == :link
      refute Map.has_key?(d.components, :text)
    end

    test "replaces the score inside the band" do
      opts = [scorer: Stubs.MidScorer, text_adapter: Stubs.LowText]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :reject
      assert d.score == 0.1
      assert d.components.text == %{before: 0.6, after: 0.1}
    end

    test "timeout produces review, not link" do
      opts = @band ++ [text_adapter: Stubs.SlowText, text_timeout: 50]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :review
      assert d.reasons == [:text_unavailable]
      assert d.components.text == %{error: :timeout}
    end

    test "an exception produces review, not link" do
      opts = @band ++ [text_adapter: Stubs.RaisingText]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert d.outcome == :review
      assert d.reasons == [:text_unavailable]
    end
  end
end
