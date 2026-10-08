defmodule AppointmentReferralLink.ThresholdTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.{Config, Score.Text.None, Threshold}

  setup do
    {:ok, c} = Config.build([])
    %{c: c}
  end

  test "outcome", %{c: c} do
    assert Threshold.outcome(0.92, c) == :link
    assert Threshold.outcome(0.99, c) == :link
    assert Threshold.outcome(0.91, c) == :review
    assert Threshold.outcome(0.35, c) == :review
    assert Threshold.outcome(0.34, c) == :reject
  end

  test "band is inclusive", %{c: c} do
    assert Threshold.in_band?(0.35, c)
    assert Threshold.in_band?(0.92, c)
    refute Threshold.in_band?(0.34, c)
    refute Threshold.in_band?(0.95, c)
  end

  test "None leaves the score unchanged", %{c: c} do
    assert None.refine(nil, nil, %{}, 0.5, c) == {:ok, 0.5}
  end
end
