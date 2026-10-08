defmodule AppointmentReferralLink.CptFamilies do
  @moduledoc """
  Specialty to CPT code ranges, shipped as data:
  `{"format": 1, "families": {"orthopedics": [["20000", "29999"], ...]}}`.
  Ranges are inclusive and compared as same-length strings.
  """

  defstruct families: %{}

  @type t :: %__MODULE__{families: %{String.t() => [{String.t(), String.t()}]}}

  @spec default_path() :: Path.t()
  def default_path,
    do: Application.app_dir(:appointment_referral_link, "priv/codes/specialty_cpt.json")

  @spec load(Path.t()) :: {:ok, t()} | {:error, {:cpt_families, Path.t(), term()}}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "families" => families}} when is_map(families) <-
           JSON.decode(body) do
      {:ok,
       %__MODULE__{families: Map.new(families, fn {s, ranges} -> {norm(s), parse(ranges)} end)}}
    else
      {:error, reason} -> {:error, {:cpt_families, path, reason}}
      _ -> {:error, {:cpt_families, path, :invalid_format}}
    end
  rescue
    _ in [FunctionClauseError, MatchError] -> {:error, {:cpt_families, path, :invalid_format}}
  end

  @doc "Number of `codes` inside the specialty's ranges; nil when unmapped or no codes."
  @spec count(t(), String.t() | nil, [String.t()] | nil) :: non_neg_integer() | nil
  def count(_t, nil, _codes), do: nil
  def count(_t, _specialty, codes) when codes in [nil, []], do: nil

  def count(%__MODULE__{families: families}, specialty, codes) do
    case Map.fetch(families, norm(specialty)) do
      :error -> nil
      {:ok, ranges} -> Enum.count(codes, &in_ranges?(String.trim(&1), ranges))
    end
  end

  defp parse(ranges),
    do: Enum.map(ranges, fn [lo, hi] when is_binary(lo) and is_binary(hi) -> {lo, hi} end)

  defp in_ranges?(code, ranges),
    do:
      Enum.any?(ranges, fn {lo, hi} ->
        byte_size(code) == byte_size(lo) and code >= lo and code <= hi
      end)

  defp norm(s), do: s |> String.trim() |> String.downcase()
end
