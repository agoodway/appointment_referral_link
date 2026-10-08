defmodule AppointmentReferralLink.Score do
  @moduledoc """
  Structured scorer. `init/1` runs once per `link/3` / `evaluate/2` call
  and loads whatever the scorer needs; `score/2` returns a probability in
  [0, 1] and a details map stored as `components.score`. Errors and
  exceptions turn the pair into `:review`.
  """

  @callback init(AppointmentReferralLink.Config.t()) :: {:ok, term()} | {:error, term()}
  @callback score(features :: map(), state :: term()) ::
              {:ok, float(), map()} | {:error, term()}
end
