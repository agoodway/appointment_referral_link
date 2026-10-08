defmodule AppointmentReferralLink.Features do
  @moduledoc """
  One flat feature map per pair. Values are atoms, numbers, booleans or
  nil; missing values stay nil and are never imputed. Laterality must
  already be filled (see `Laterality.fill/2`) before calling `build/4`.
  """

  alias AppointmentReferralLink.{Appointment, CptFamilies, Gate, Laterality, Ontology, Referral}

  @names [
    :days_from_issue,
    :days_from_auth_start,
    :days_to_auth_end,
    :specialty_match,
    :subspecialty_match,
    :body_part_match,
    :laterality_match,
    :icd_overlap,
    :cpt_in_referral_family,
    :same_referring_provider,
    :booked_from_referral,
    :appointment_status,
    :site_match,
    :already_linked,
    :laterality_missing,
    :body_part_missing,
    :specialty_missing,
    :icd_missing
  ]

  @spec names() :: [atom()]
  def names, do: @names

  @spec build(Referral.t(), Appointment.t(), Ontology.t(), CptFamilies.t()) :: map()
  def build(%Referral{} = r, %Appointment{} = a, ontology, cpt) do
    %{
      days_from_issue: diff(a.starts_on, r.issued_on),
      days_from_auth_start: diff(a.starts_on, r.auth_start),
      days_to_auth_end: diff(r.auth_end, a.starts_on),
      specialty_match: specialty_match(r, a),
      subspecialty_match: Ontology.match(ontology, a.subspecialty, r.body_part),
      body_part_match: Ontology.match(ontology, a.body_part, r.body_part),
      laterality_match: Laterality.compare(r.laterality, a.laterality),
      icd_overlap: icd_overlap(r.icd10, a.icd10),
      cpt_in_referral_family: CptFamilies.count(cpt, r.specialty, a.cpt),
      same_referring_provider: same(r.referring_provider_id, a.rendering_provider_id),
      booked_from_referral: a.booked_from_referral,
      appointment_status: a.status,
      site_match: same(r.site_id, a.site_id),
      already_linked: Gate.Window.linked_elsewhere?(r, a),
      laterality_missing: is_nil(r.laterality) or is_nil(a.laterality),
      body_part_missing: is_nil(r.body_part) or is_nil(a.body_part),
      specialty_missing: is_nil(r.specialty) or is_nil(a.specialty),
      icd_missing: empty?(r.icd10) or empty?(a.icd10)
    }
  end

  @doc """
  The feature map as a `rule_match` candidate. `rule_match` compares
  atoms and strings as different values, so atom values (other than
  booleans and nil) become strings.
  """
  @spec to_candidate(map()) :: map()
  def to_candidate(features), do: Map.new(features, fn {k, v} -> {k, encode(v)} end)

  defp encode(v) when is_boolean(v) or is_nil(v), do: v
  defp encode(v) when is_atom(v), do: Atom.to_string(v)
  defp encode(v), do: v

  defp diff(%Date{} = a, %Date{} = b), do: Date.diff(a, b)
  defp diff(_, _), do: nil

  defp specialty_match(%{specialty: rs}, %{specialty: as}) when is_nil(rs) or is_nil(as), do: nil

  defp specialty_match(r, a) do
    s = norm(a.specialty)

    cond do
      s == norm(r.specialty) -> :exact
      s in Enum.map(r.allowed_specialties || [], &norm/1) -> :allowed
      true -> :mismatch
    end
  end

  defp icd_overlap(r, a) do
    if empty?(r) or empty?(a) do
      nil
    else
      appointment_categories = categories(a)
      r |> categories() |> Enum.count(&MapSet.member?(appointment_categories, &1))
    end
  end

  defp categories(codes),
    do: codes |> Enum.map(&(&1 |> String.trim() |> String.upcase() |> String.slice(0, 3))) |> MapSet.new()

  defp same(nil, _), do: nil
  defp same(_, nil), do: nil
  defp same(a, b), do: a == b

  defp empty?(list), do: list in [nil, []]

  defp norm(s), do: s |> String.trim() |> String.downcase()
end
