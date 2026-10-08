defmodule AppointmentReferralLink.HardeningTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.Stubs

  @band [review_low: 0.0, review_high: 1.0]

  describe "caller field types are validated, not crashed on" do
    for {label, attrs} <- [
          {"string status", [status: "cancelled"]},
          {"unknown status atom", [status: :checked_in]},
          {"string laterality", [laterality: "right"]},
          {"integer icd code", [icd10: [123]]},
          {"integer cpt code", [cpt: [27447]]},
          {"atom specialty", [specialty: :orthopedics]},
          {"atom body part", [body_part: :knee]},
          {"atom reason", [reason: :knee, laterality: nil]},
          {"string date", [starts_on: "2026-09-18"]},
          {"datetime date", [starts_on: ~U[2026-09-18 10:00:00Z]]},
          {"non-boolean booked flag", [booked_from_referral: "yes"]}
        ] do
      test "appointment #{label}" do
        assert {:error, {:invalid_input, _}} =
                 AppointmentReferralLink.link(referral(), [
                   appointment(unquote(Macro.escape(attrs)))
                 ])
      end
    end

    for {label, attrs} <- [
          {"string issued_on", [issued_on: "2026-09-01"]},
          {"string auth_end", [auth_end: "2026-12-01"]},
          {"integer allowed specialty", [allowed_specialties: [1]]},
          {"patient not a map", [patient: "alice"]}
        ] do
      test "referral #{label}" do
        assert {:error, {:invalid_input, _}} =
                 AppointmentReferralLink.link(referral(unquote(Macro.escape(attrs))), [
                   appointment()
                 ])
      end
    end

    test "nil code lists are accepted as missing" do
      assert {:ok, [_]} =
               AppointmentReferralLink.link(referral(icd10: nil, allowed_specialties: nil), [
                 appointment(cpt: nil, icd10: nil)
               ])
    end
  end

  test "blank patient ids never pass the exact gate" do
    {:ok, [d]} =
      AppointmentReferralLink.link(referral(patient_id: ""), [appointment(patient_id: "")])

    assert d.reasons == [:patient_mismatch]
  end

  describe "scorer throws and exits go to review" do
    for scorer <- [Stubs.ThrowingScorer, Stubs.ExitingScorer] do
      test "#{inspect(scorer)}" do
        {:ok, [d]} =
          AppointmentReferralLink.link(referral(), [appointment()], scorer: unquote(scorer))

        assert {d.outcome, d.reasons} == {:review, [:scorer_error]}
      end
    end
  end

  describe "text adapter isolation" do
    test "a linked crash inside the adapter gives review and does not kill the caller" do
      opts = @band ++ [text_adapter: Stubs.LinkedCrashText]
      {:ok, [d]} = AppointmentReferralLink.link(referral(), [appointment()], opts)
      assert {d.outcome, d.reasons} == {:review, [:text_unavailable]}
    end

    test "a trapping caller gets no leftover messages" do
      Process.flag(:trap_exit, true)
      opts = @band ++ [text_adapter: AppointmentReferralLink.Score.Text.None]

      {:ok, _} =
        AppointmentReferralLink.link(
          referral(),
          [appointment(id: "a"), appointment(id: "b")],
          opts
        )

      {:ok, _} =
        AppointmentReferralLink.link(
          referral(),
          [appointment()],
          @band ++ [text_adapter: Stubs.SlowText, text_timeout: 20]
        )

      Process.sleep(50)
      assert Process.info(self(), :messages) == {:messages, []}
    end
  end

  describe "malformed data files return errors" do
    @describetag :tmp_dir

    for {label, key, body} <- [
          {"ontology synonyms not a list", :ontology_paths,
           ~s({"format": 1, "parts": {"knee": {"synonyms": "knee joint"}}})},
          {"ontology non-string synonym", :ontology_paths,
           ~s({"format": 1, "parts": {"knee": {"synonyms": [1]}}})},
          {"cpt ranges not a list", :cpt_families,
           ~s({"format": 1, "families": {"orthopedics": "20000"}})},
          {"rules not a list", :conflict_rules, ~s({"format": 1, "rules": "x"})},
          {"normalize not a map", :conflict_rules,
           ~s({"format": 1, "normalize": "x", "rules": []})},
          {"score rules not a list", :score_rules,
           ~s({"format": 1, "meta": {"intercept": 0}, "rules": "x"})}
        ] do
      test label, %{tmp_dir: dir} do
        path = Path.join(dir, "bad.json")
        File.write!(path, unquote(body))
        value = if unquote(key) == :ontology_paths, do: [path], else: path

        assert {:error, _} =
                 AppointmentReferralLink.link(referral(), [appointment()], [{unquote(key), value}])
      end
    end
  end
end
