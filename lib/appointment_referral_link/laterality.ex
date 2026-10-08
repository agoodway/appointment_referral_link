defmodule AppointmentReferralLink.Laterality do
  @moduledoc """
  Laterality tokens from free text, used only to fill a missing
  structured field. No other narrative parsing.
  """

  @right ~w(rt right)
  @left ~w(lt left)
  @bilateral ~w(bilateral bilat both)

  @type t :: :left | :right | :bilateral | nil

  @spec from_text(String.t() | nil) :: t()
  def from_text(nil), do: nil

  def from_text(text) when is_binary(text) do
    tokens = text |> String.downcase() |> String.split(~r/[^a-z]+/, trim: true) |> MapSet.new()
    has? = fn words -> Enum.any?(words, &MapSet.member?(tokens, &1)) end
    right? = has?.(@right)
    left? = has?.(@left)

    cond do
      has?.(@bilateral) or (right? and left?) -> :bilateral
      right? -> :right
      left? -> :left
      true -> nil
    end
  end

  @spec fill(t(), String.t() | nil) :: t()
  def fill(nil, text), do: from_text(text)
  def fill(laterality, _text), do: laterality

  @spec compare(t(), t()) :: :agree | :conflict | :unknown
  def compare(nil, _), do: :unknown
  def compare(_, nil), do: :unknown
  def compare(same, same), do: :agree
  def compare(:bilateral, _), do: :agree
  def compare(_, :bilateral), do: :agree
  def compare(_, _), do: :conflict
end
