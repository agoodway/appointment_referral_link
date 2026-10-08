defmodule AppointmentReferralLink.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.Stubs

  # Worst case: the scorer and the text adapter both claim 0.99, and the
  # text adapter sees every pair.
  @hostile [
    scorer: Stubs.HighScorer,
    text_adapter: Stubs.HighText,
    review_low: 0.0,
    review_high: 1.0
  ]

  @alice %{
    given_name: "Alice",
    family_name: "Example",
    dob: "1980-01-10",
    sex: "F",
    zip: "02139",
    phone: "2125550101",
    ssn: "212456789"
  }
  @others [
    %{
      given_name: "Carol",
      family_name: "Fiction",
      dob: "1980-09-15",
      sex: "F",
      zip: "60601",
      phone: "3125550103",
      ssn: "345678901"
    },
    %{
      given_name: "Brian",
      family_name: "Sample",
      dob: "1980-06-12",
      sex: "M",
      zip: "10001",
      phone: "2125550102",
      ssn: "234567890"
    }
  ]

  setup_all do
    records =
      [@alice | @others]
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> Map.put(p, :id, "t#{i}") end)
      |> Kernel.++([
        %{
          id: "t9",
          given_name: "Alicx",
          family_name: "Example",
          dob: "1980-01-10",
          sex: "F",
          zip: "02139",
          phone: "5550101",
          ssn: "212456789"
        },
        %{
          id: "t10",
          given_name: "Brian",
          family_name: "Sample",
          dob: "1980-06-13",
          sex: "M",
          zip: nil,
          phone: "2125550102",
          ssn: "234567890"
        }
      ])

    %{model: PatientMatching.train(records, PatientMatching.Presets.patient_mpi())}
  end

  defp decide(r, a, opts \\ @hostile) do
    {:ok, [d]} = AppointmentReferralLink.link(r, [a], opts)
    d
  end

  # Pairs that pass every gate. Window for referral/0 is issued_on-7 .. issued_on+105.
  defp clean_pair do
    gen all(
          offset <- integer(-7..105),
          specialty <- member_of(["orthopedics", "sports_medicine", " Orthopedics"]),
          part <- member_of(["knee", "medial knee", "patella", nil]),
          lat <- member_of([:right, :bilateral, nil]),
          booked <- member_of([true, false, nil]),
          status <- member_of([:booked, :completed])
        ) do
      r = referral()

      a =
        appointment(
          starts_on: Date.add(r.issued_on, offset),
          specialty: specialty,
          body_part: part,
          laterality: lat,
          reason: "knee pain",
          booked_from_referral: booked,
          status: status
        )

      {r, a}
    end
  end

  property "control: clean pairs link under the hostile stubs (properties are not vacuous)" do
    check all({r, a} <- clean_pair()) do
      assert decide(r, a).outcome == :link
    end
  end

  property "a laterality conflict never links" do
    check all(
            {r, a} <- clean_pair(),
            {r_lat, r_reason, a_lat, a_reason} <-
              member_of([
                {:right, "pain", :left, "pain"},
                {:right, "pain", nil, "lt knee pain"},
                {:right, "pain", nil, "LEFT knee"},
                {nil, "right knee", :left, "pain"},
                {:left, "pain", :right, "pain"}
              ])
          ) do
      d =
        decide(%{r | laterality: r_lat, reason: r_reason}, %{
          a
          | laterality: a_lat,
            reason: a_reason
        })

      assert d.outcome == :reject
      assert :laterality_conflict in d.reasons
    end
  end

  property "a failed exact patient gate never links" do
    check all(
            {r, a} <- clean_pair(),
            other <- one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
            other != "p_9"
          ) do
      d = decide(r, %{a | patient_id: other})
      assert d.outcome == :reject
      assert d.reasons == [:patient_mismatch]
    end
  end

  property "a pair outside the window never links" do
    check all(
            {r, a} <- clean_pair(),
            offset <- one_of([integer(-400..-8), integer(106..400)])
          ) do
      d = decide(r, %{a | starts_on: Date.add(r.issued_on, offset)})
      assert d.outcome == :reject
      assert :outside_window in d.reasons
    end
  end

  property "excluded statuses never link" do
    check all({r, a} <- clean_pair(), status <- member_of([:cancelled, :no_show])) do
      d = decide(r, %{a | status: status})
      assert d.outcome == :reject
      assert :status_excluded in d.reasons
    end
  end

  property "an appointment linked to another referral never links" do
    check all(
            {r, a} <- clean_pair(),
            other <- string(:alphanumeric, min_length: 1),
            other != r.id
          ) do
      d = decide(r, %{a | linked_referral_id: other})
      assert d.outcome == :reject
      assert :already_linked in d.reasons
    end
  end

  property "a failed FS gate never links, even with matching patient_id", %{model: model} do
    opts = @hostile ++ [patient_gate: {:fellegi_sunter, model}]

    check all({r, a} <- clean_pair(), other <- member_of(@others), max_runs: 25) do
      d = decide(%{r | patient: @alice}, %{a | patient: other}, opts)
      assert d.outcome == :reject
      assert d.reasons == [:patient_mismatch]
    end
  end
end
