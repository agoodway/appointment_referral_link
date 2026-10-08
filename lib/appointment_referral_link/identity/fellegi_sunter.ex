defmodule AppointmentReferralLink.Identity.FellegiSunter do
  @moduledoc """
  Optional identity comparator for source systems that share no patient
  identifier. Wraps `patient_matching`: the caller trains the model, and
  this module only loads it and scores one pair. The score is used for
  the gate and nothing downstream.
  """

  @spec load(struct() | {String.t(), struct()} | term()) ::
          {:ok, struct()} | {:error, {:fs_model, String.t()}}
  def load(%PatientMatching.Model{} = model), do: {:ok, model}

  def load({json, config}) when is_binary(json) do
    {:ok, PatientMatching.load(json, config)}
  rescue
    e -> {:error, {:fs_model, Exception.message(e)}}
  end

  def load(other), do: {:error, {:fs_model, "unsupported model: #{inspect(other, limit: 3)}"}}

  @doc "Scores the two `patient` maps. Nil when either side has none."
  @spec compare(map(), map(), struct()) :: %{probability: float(), guards: [atom()]} | nil
  def compare(%{id: rid, patient: rp}, %{id: aid, patient: ap}, model)
      when is_map(rp) and is_map(ap) do
    result =
      PatientMatching.explain(
        Map.put(rp, :id, {:referral, rid}),
        Map.put(ap, :id, {:appointment, aid}),
        model
      )

    %{probability: result.probability, guards: result.guards}
  end

  def compare(_referral, _appointment, _model), do: nil
end
