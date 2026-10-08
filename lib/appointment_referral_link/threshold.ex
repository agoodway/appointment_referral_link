defmodule AppointmentReferralLink.Threshold do
  @moduledoc "Turns a final probability into an outcome. The only place `:link` comes from."

  alias AppointmentReferralLink.Config

  @spec in_band?(float(), Config.t()) :: boolean()
  def in_band?(p, %Config{review_low: low, review_high: high}), do: p >= low and p <= high

  @spec outcome(float(), Config.t()) :: :link | :reject | :review
  def outcome(p, %Config{link_at: link_at, reject_at: reject_at}) do
    cond do
      p >= link_at -> :link
      p < reject_at -> :reject
      true -> :review
    end
  end
end
