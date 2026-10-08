defmodule AppointmentReferralLink.Stubs do
  @moduledoc false

  defmodule HighScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 0.99, %{}}
  end

  defmodule MidScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 0.6, %{}}
  end

  defmodule RaisingScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: raise("scorer down")
  end

  defmodule BadScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 1.5, %{}}
  end

  defmodule IntScorer do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score
    @impl true
    def init(_config), do: {:ok, nil}
    @impl true
    def score(_features, _state), do: {:ok, 1, %{}}
  end

  defmodule HighText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: {:ok, 0.99}
  end

  defmodule LowText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: {:ok, 0.1}
  end

  defmodule SlowText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c) do
      Process.sleep(1_000)
      {:ok, 0.99}
    end
  end

  defmodule RaisingText do
    @moduledoc false
    @behaviour AppointmentReferralLink.Score.Text
    @impl true
    def refine(_r, _a, _f, _p, _c), do: raise("text service down")
  end
end
