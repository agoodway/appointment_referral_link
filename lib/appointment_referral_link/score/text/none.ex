defmodule AppointmentReferralLink.Score.Text.None do
  @moduledoc "Text adapter that leaves the structured score unchanged."

  @behaviour AppointmentReferralLink.Score.Text

  @impl true
  def refine(_referral, _appointment, _features, p, _config), do: {:ok, p}
end
