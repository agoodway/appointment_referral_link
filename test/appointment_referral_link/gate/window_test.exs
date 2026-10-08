defmodule AppointmentReferralLink.Gate.WindowTest do
  use ExUnit.Case, async: true

  import AppointmentReferralLink.Fixtures
  alias AppointmentReferralLink.{Config, Gate.Window}

  setup do
    {:ok, config} = Config.build([])
    %{c: config}
  end

  test "window is issued_on - lead_days to auth_end + lag_days", %{c: c} do
    assert Window.window(referral(), c) == {~D[2026-08-25], ~D[2026-12-15]}
  end

  test "without auth_end the window ends default_auth_days after issue", %{c: c} do
    assert Window.window(referral(auth_end: nil), c) == {~D[2026-08-25], ~D[2026-12-14]}
  end

  test "both edges are inclusive", %{c: c} do
    assert Window.check(referral(), appointment(starts_on: ~D[2026-08-25]), c) == []
    assert Window.check(referral(), appointment(starts_on: ~D[2026-12-15]), c) == []
    assert Window.check(referral(), appointment(starts_on: ~D[2026-08-24]), c) == [:outside_window]
    assert Window.check(referral(), appointment(starts_on: ~D[2026-12-16]), c) == [:outside_window]
  end

  test "nil dates fall outside the window instead of crashing", %{c: c} do
    assert Window.check(referral(issued_on: nil), appointment(), c) == [:outside_window]
    assert Window.check(referral(), appointment(starts_on: nil), c) == [:outside_window]
  end

  test "dropped statuses are excluded", %{c: c} do
    assert Window.check(referral(), appointment(status: :cancelled), c) == [:status_excluded]
    assert Window.check(referral(), appointment(status: :no_show), c) == [:status_excluded]
    assert Window.check(referral(), appointment(status: :booked), c) == []
  end

  test "drop_statuses is configurable" do
    {:ok, c} = Config.build(drop_statuses: [])
    assert Window.check(referral(), appointment(status: :cancelled), c) == []
  end

  test "linked to a different referral is already_linked", %{c: c} do
    assert Window.check(referral(), appointment(linked_referral_id: "ref_2"), c) == [:already_linked]
  end

  test "linked to this same referral is not already_linked", %{c: c} do
    assert Window.check(referral(), appointment(linked_referral_id: "ref_1"), c) == []
  end

  test "collects every failing reason", %{c: c} do
    appt = appointment(starts_on: ~D[2027-06-01], status: :no_show, linked_referral_id: "ref_9")
    assert Window.check(referral(), appt, c) == [:outside_window, :status_excluded, :already_linked]
  end
end
