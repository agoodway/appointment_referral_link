defmodule AppointmentReferralLink.Gate.PatientTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, Gate.Patient, Identity.FellegiSunter}

  # Synthetic records from the patient_matching README.
  @alice %{
    given_name: "Alice",
    family_name: "Example",
    dob: "1980-01-10",
    sex: "F",
    zip: "02139",
    phone: "2125550101",
    ssn: "212456789"
  }
  @carol %{
    given_name: "Carol",
    family_name: "Fiction",
    dob: "1980-09-15",
    sex: "F",
    zip: "60601",
    phone: "3125550103",
    ssn: "345678901"
  }

  setup_all do
    records = [
      Map.put(@alice, :id, "a1"),
      %{
        id: "a2",
        given_name: "Brian",
        family_name: "Sample",
        dob: "1980-06-12",
        sex: "M",
        zip: "10001",
        phone: "2125550102",
        ssn: "234567890"
      },
      Map.put(@carol, :id, "a3"),
      %{
        id: "b1",
        given_name: "Alicx",
        family_name: "Example",
        dob: "1980-01-10",
        sex: "F",
        zip: "02139",
        phone: "5550101",
        ssn: "212456789"
      },
      %{
        id: "b2",
        given_name: "Brian",
        family_name: "Sample",
        dob: "1980-06-13",
        sex: "M",
        zip: nil,
        phone: "2125550102",
        ssn: "234567890"
      }
    ]

    model = PatientMatching.train(records, PatientMatching.Presets.patient_mpi())
    %{model: model}
  end

  describe "exact gate" do
    setup do
      {:ok, c} = Config.build([])
      %{c: c}
    end

    test "passes on equal patient_id", %{c: c} do
      assert {:pass, nil} = Patient.check(referral(), appointment(), c)
    end

    test "fails on a different or nil patient_id", %{c: c} do
      assert {:fail, nil} = Patient.check(referral(), appointment(patient_id: "p_10"), c)

      assert {:fail, nil} =
               Patient.check(referral(patient_id: nil), appointment(patient_id: nil), c)
    end
  end

  describe "Fellegi–Sunter gate" do
    setup %{model: model} do
      {:ok, c} = Config.build(patient_gate: {:fellegi_sunter, model})
      {:ok, loaded} = FellegiSunter.load(model)
      %{c: %{c | fs_model: loaded}}
    end

    test "the same person passes, ignoring patient_id", %{c: c} do
      r = referral(patient_id: "src_a_1", patient: @alice)
      a = appointment(patient_id: "src_b_77", patient: @alice)
      assert {:pass, %{probability: p, guards: []}} = Patient.check(r, a, c)
      assert p >= 0.95
    end

    test "a different person fails", %{c: c} do
      r = referral(patient: @alice)
      a = appointment(patient: @carol)
      assert {:fail, %{probability: p}} = Patient.check(r, a, c)
      assert p < 0.95
    end

    test "missing demographics fail", %{c: c} do
      assert {:fail, nil} = Patient.check(referral(patient: nil), appointment(patient: @alice), c)
    end
  end

  test "load/1 accepts a dumped model with its config", %{model: model} do
    config = PatientMatching.Presets.patient_mpi()
    assert {:ok, _} = FellegiSunter.load({PatientMatching.dump(model), config})
    assert {:error, {:fs_model, _}} = FellegiSunter.load({"{}", config})
    assert {:error, {:fs_model, _}} = FellegiSunter.load(:nope)
  end
end
