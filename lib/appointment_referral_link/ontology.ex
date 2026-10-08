defmodule AppointmentReferralLink.Ontology do
  @moduledoc """
  Body-part vocabulary shipped as data. Each canonical part has synonyms
  (the same part) and children (a narrower region of it). Sites extend it
  with extra files through the `:ontology_paths` option; files merge by
  union.

  File format: `{"format": 1, "parts": {"knee": {"synonyms": [...], "children": [...]}}}`.
  """

  defstruct index: %{}

  @type t :: %__MODULE__{index: %{String.t() => {String.t(), :self | :child}}}
  @type match :: :exact | :related | :mismatch | :unknown

  @spec default_path() :: Path.t()
  def default_path,
    do: Application.app_dir(:appointment_referral_link, "priv/ontology/body_parts.json")

  @spec load([Path.t()]) :: {:ok, t()} | {:error, {:ontology, Path.t(), term()}}
  def load(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read(path) do
        {:ok, parts} -> {:cont, {:ok, merge(acc, parts)}}
        {:error, reason} -> {:halt, {:error, {:ontology, path, reason}}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, %__MODULE__{index: index(parts)}}
      error -> error
    end
  end

  @doc "Compares two terms. Nil or unknown terms give `:unknown`."
  @spec match(t(), String.t() | nil, String.t() | nil) :: match()
  def match(_ontology, nil, _), do: :unknown
  def match(_ontology, _, nil), do: :unknown

  def match(%__MODULE__{index: index}, a, b) do
    na = normalize(a)
    nb = normalize(b)

    case {Map.get(index, na), Map.get(index, nb)} do
      {nil, _} -> :unknown
      {_, nil} -> :unknown
      {{c, _}, {c, _}} when na == nb -> :exact
      {{c, :self}, {c, :self}} -> :exact
      {{c, _}, {c, _}} -> :related
      _ -> :mismatch
    end
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(term),
    do: term |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "parts" => parts}} when is_map(parts) <- JSON.decode(body),
         true <- Enum.all?(parts, fn {_, spec} -> valid_spec?(spec) end) do
      {:ok,
       Map.new(parts, fn {name, spec} ->
         {normalize(name),
          %{synonyms: terms(spec, "synonyms"), children: terms(spec, "children")}}
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_format}
    end
  end

  defp valid_spec?(spec) when is_map(spec),
    do: Enum.all?(~w(synonyms children), &strings?(Map.get(spec, &1, [])))

  defp valid_spec?(_spec), do: false

  defp strings?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp terms(spec, key), do: spec |> Map.get(key, []) |> Enum.map(&normalize/1) |> MapSet.new()

  defp merge(acc, parts) do
    Map.merge(acc, parts, fn _name, a, b ->
      %{
        synonyms: MapSet.union(a.synonyms, b.synonyms),
        children: MapSet.union(a.children, b.children)
      }
    end)
  end

  # Canonical names and synonyms win over a child entry with the same text.
  defp index(parts) do
    children =
      for {canon, spec} <- parts, child <- spec.children, into: %{}, do: {child, {canon, :child}}

    selves =
      for {canon, spec} <- parts,
          term <- [canon | MapSet.to_list(spec.synonyms)],
          into: %{},
          do: {term, {canon, :self}}

    Map.merge(children, selves)
  end
end
