defmodule AppointmentReferralLink.EvaluateTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.Report

  test "Report.build/1 arithmetic" do
    report =
      Report.build([
        {:link, true, false},
        {:link, false, true},
        {:review, true, false},
        {:reject, false, false}
      ])

    assert report.total == 4
    assert report.precision == 0.5
    assert report.recall == 0.5
    assert report.review_rate == 0.25
    assert report.cross_referral_false_link_rate == 0.5

    assert report.counts == %{
             {:link, true} => 1,
             {:link, false} => 1,
             {:review, true} => 1,
             {:reject, false} => 1
           }
  end

  test "empty and link-free reports" do
    assert %Report{
             total: 0,
             precision: nil,
             recall: nil,
             review_rate: nil,
             cross_referral_false_link_rate: +0.0
           } =
             Report.build([])

    assert %Report{precision: nil, cross_referral_false_link_rate: +0.0} =
             Report.build([{:reject, true, false}])
  end

  test "evaluate/2 counts a false link to the wrong referral as cross-referral" do
    r1 = referral()
    r2 = referral(id: "ref_2")
    appt = appointment(id: "appt_x")

    labeled = [
      %{referral: r1, appointment: appt, label: false},
      %{referral: r2, appointment: appt, label: true}
    ]

    report = AppointmentReferralLink.evaluate(labeled)
    assert report.counts == %{{:link, false} => 1, {:link, true} => 1}
    assert report.precision == 0.5
    assert report.cross_referral_false_link_rate == 0.5
  end

  test "evaluate/2 passes options through and raises on invalid config" do
    labeled = [%{referral: referral(), appointment: appointment(), label: true}]

    assert %Report{counts: %{{:review, true} => 1}} =
             AppointmentReferralLink.evaluate(labeled, link_at: 0.99)

    assert_raise ArgumentError, fn ->
      AppointmentReferralLink.evaluate(labeled, reject_at: 2.0)
    end
  end

  describe "evaluate/2 validates rows" do
    test "a row with a malformed field raises ArgumentError naming the row" do
      labeled = [
        %{referral: referral(), appointment: appointment(), label: true},
        %{referral: referral(), appointment: appointment(status: "cancelled"), label: false}
      ]

      error = assert_raise ArgumentError, fn -> AppointmentReferralLink.evaluate(labeled) end
      assert error.message =~ "row 1"
    end

    test "a row of the wrong shape or with a non-boolean label raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        AppointmentReferralLink.evaluate([%{referral: referral()}])
      end

      assert_raise ArgumentError, fn ->
        AppointmentReferralLink.evaluate([
          %{referral: referral(), appointment: appointment(), label: "yes"}
        ])
      end
    end
  end
end
