defmodule AppointmentReferralLink.Score.Tree.Encoder do
  @moduledoc """
  Turns a feature map into the fixed numeric row the ONNX model was
  trained on. The column file sits next to the model:

      {"format": 1, "columns": [
        {"name": "days_from_issue"},
        {"name": "laterality_match", "one_hot": ["agree", "conflict", "unknown"]}]}

  Numbers pass through as floats, booleans become 1.0/0.0, categoricals
  become one-hot, and nil becomes NaN (all NaN for a one-hot group).
  """

  alias AppointmentReferralLink.Features

  @type column :: {:numeric, String.t()} | {:one_hot, String.t(), [String.t()]}

  @spec load(Path.t()) :: {:ok, [column()]} | {:error, {:tree_columns, Path.t(), term()}}
  def load(path) do
    known = Enum.map(Features.names(), &Atom.to_string/1)

    with {:ok, body} <- File.read(path),
         {:ok, %{"format" => 1, "columns" => cols}} when is_list(cols) <- JSON.decode(body),
         {:ok, columns} <- columns(cols, known) do
      {:ok, columns}
    else
      {:error, reason} -> {:error, {:tree_columns, path, reason}}
      _ -> {:error, {:tree_columns, path, :invalid_format}}
    end
  end

  @spec encode(map(), [column()]) :: [float() | :nan]
  def encode(features, columns) do
    values = Map.new(Features.to_candidate(features), fn {k, v} -> {Atom.to_string(k), v} end)

    Enum.flat_map(columns, fn
      {:numeric, name} ->
        [numeric(Map.get(values, name))]

      {:one_hot, name, categories} ->
        case Map.get(values, name) do
          nil -> List.duplicate(:nan, length(categories))
          value -> Enum.map(categories, &if(&1 == value, do: 1.0, else: 0.0))
        end
    end)
  end

  defp columns(cols, known) do
    Enum.reduce_while(cols, {:ok, []}, fn col, {:ok, acc} ->
      case column(col) do
        {:ok, {_, name} = c} -> check(name, c, acc, known)
        {:ok, {_, name, _} = c} -> check(name, c, acc, known)
        :error -> {:halt, {:error, {:bad_column, col}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check(name, column, acc, known) do
    if name in known,
      do: {:cont, {:ok, [column | acc]}},
      else: {:halt, {:error, {:unknown_feature, name}}}
  end

  defp column(%{"name" => name, "one_hot" => cats}) when is_binary(name) and is_list(cats),
    do: {:ok, {:one_hot, name, cats}}

  defp column(%{"name" => name}) when is_binary(name), do: {:ok, {:numeric, name}}
  defp column(_), do: :error

  defp numeric(nil), do: :nan
  defp numeric(true), do: 1.0
  defp numeric(false), do: 0.0
  defp numeric(n) when is_number(n), do: n * 1.0
  defp numeric(_), do: :nan
end
