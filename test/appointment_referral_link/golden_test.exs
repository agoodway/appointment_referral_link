defmodule AppointmentReferralLink.GoldenTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Fixtures

  @golden Path.expand("../fixtures/golden.json", __DIR__)
  @baseline Path.expand("../fixtures/baseline.json", __DIR__)

  for c <- Fixtures.load_cases(Path.expand("../fixtures/golden.json", __DIR__)) do
    @case c
    test "golden: #{c.name}" do
      %{referral: r, appointment: a, expected: expected, reasons: reasons} = @case
      {:ok, [d]} = AppointmentReferralLink.link(r, [a])

      assert {d.outcome, d.reasons} == {expected, reasons},
             "#{@case.name}: #{inspect(d, pretty: true)}"
    end
  end

  test "evaluation gate: precision and cross-referral false-link rate hold the baseline" do
    baseline = @baseline |> File.read!() |> JSON.decode!()

    labeled =
      Enum.map(Fixtures.load_cases(@golden), &Map.take(&1, [:referral, :appointment, :label]))

    report = AppointmentReferralLink.evaluate(labeled)

    assert report.precision >= baseline["precision_min"],
           "precision dropped: #{inspect(report)}"

    assert report.cross_referral_false_link_rate <= baseline["cross_referral_false_link_rate_max"],
           "cross-referral false-link rate rose: #{inspect(report)}"
  end
end
