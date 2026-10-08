defmodule AppointmentReferralLink.FeaturesTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{CptFamilies, Features, Ontology}

  setup do
    {:ok, o} = Ontology.load([Ontology.default_path()])
    {:ok, cpt} = CptFamilies.load(CptFamilies.default_path())
    %{o: o, cpt: cpt}
  end

  test "base pair features", %{o: o, cpt: cpt} do
    f = Features.build(referral(), appointment(), o, cpt)

    assert Map.keys(f) |> Enum.sort() == Enum.sort(Features.names())
    assert f.days_from_issue == 17
    assert f.days_from_auth_start == 17
    assert f.days_to_auth_end == 74
    assert f.specialty_match == :exact
    assert f.subspecialty_match == :exact
    assert f.body_part_match == :exact
    assert f.laterality_match == :agree
    assert f.icd_overlap == 1
    assert f.cpt_in_referral_family == 1
    assert f.same_referring_provider == false
    assert f.booked_from_referral == true
    assert f.appointment_status == :completed
    assert f.site_match == true
    assert f.already_linked == false
    refute f.laterality_missing or f.body_part_missing or f.specialty_missing or f.icd_missing
  end

  test "specialty compares case- and whitespace-insensitively", %{o: o, cpt: cpt} do
    f = Features.build(referral(), appointment(specialty: " Orthopedics "), o, cpt)
    assert f.specialty_match == :exact
    f = Features.build(referral(), appointment(specialty: "Sports_Medicine"), o, cpt)
    assert f.specialty_match == :allowed
    f = Features.build(referral(), appointment(specialty: "cardiology"), o, cpt)
    assert f.specialty_match == :mismatch
  end

  test "missing values stay nil and set missingness flags", %{o: o, cpt: cpt} do
    r = referral(specialty: nil, auth_end: nil, auth_start: nil, laterality: nil, icd10: [])
    a = appointment(body_part: nil, site_id: nil, cpt: [], booked_from_referral: nil)
    f = Features.build(r, a, o, cpt)

    assert f.specialty_match == nil
    assert f.days_to_auth_end == nil
    assert f.days_from_auth_start == nil
    assert f.laterality_match == :unknown
    assert f.body_part_match == :unknown
    assert f.icd_overlap == nil
    assert f.cpt_in_referral_family == nil
    assert f.site_match == nil
    assert f.booked_from_referral == nil
    assert f.laterality_missing and f.body_part_missing and f.specialty_missing and f.icd_missing
  end

  test "icd_overlap counts shared 3-character categories", %{o: o, cpt: cpt} do
    r = referral(icd10: ["M23.20", "M25.561", "m23.9"])
    a = appointment(icd10: ["M23.21", "M25.50", "S83.2"])
    assert Features.build(r, a, o, cpt).icd_overlap == 2
    assert Features.build(r, appointment(icd10: ["S83.2"]), o, cpt).icd_overlap == 0
  end

  test "cpt counts codes in the referral specialty's ranges", %{o: o, cpt: cpt} do
    a = appointment(cpt: ["99203", "29881", "93000"])
    assert Features.build(referral(), a, o, cpt).cpt_in_referral_family == 2
    assert Features.build(referral(specialty: "dermatology"), a, o, cpt).cpt_in_referral_family == nil
  end

  test "to_candidate stringifies atoms but keeps booleans, nil and numbers" do
    assert Features.to_candidate(%{a: :agree, b: true, c: nil, d: 3, e: false}) ==
             %{a: "agree", b: true, c: nil, d: 3, e: false}
  end
end
