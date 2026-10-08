if Code.ensure_loaded?(Ortex) do
  defmodule AppointmentReferralLink.Score.Tree do
    @moduledoc """
    Gradient-boosted tree exported to ONNX, run through Ortex. Compiled
    only when the optional `:ortex` dependency is present.

    The model must take one float32 input of shape `{n, columns}` and
    return `{label, probabilities}` with probabilities `{n, 2}`. For
    scikit-learn, export with `skl2onnx` and `options={"zipmap": False}`.
    The loaded model is cached in `:persistent_term` per path and reloaded
    when the file's modification time or size changes, so a model replaced
    in place is picked up by the next `link/3` call.
    """

    @behaviour AppointmentReferralLink.Score

    alias AppointmentReferralLink.{Config, Rules, Score.Tree.Encoder}

    @impl true
    def init(%Config{} = c) do
      model_path = c.tree_model_path || Rules.priv("priv/models/linker.onnx")

      columns_path =
        c.tree_columns_path || Path.join(Path.dirname(model_path), "linker.features.json")

      with {:ok, columns} <- Encoder.load(columns_path),
           {:ok, model} <- model(model_path) do
        {:ok, %{model: model, columns: columns, path: model_path}}
      end
    end

    @impl true
    def score(features, %{model: model, columns: columns, path: path}) do
      input = Nx.tensor([Encoder.encode(features, columns)], type: :f32)
      {_label, probabilities} = Ortex.run(model, input)
      p = probabilities |> Nx.to_flat_list() |> Enum.at(1)
      {:ok, p * 1.0, %{model: path, columns: length(columns)}}
    end

    defp model(path) do
      key = {__MODULE__, path}

      with {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(path, time: :posix) do
        stamp = {mtime, size}

        case :persistent_term.get(key, nil) do
          {^stamp, model} ->
            {:ok, model}

          _stale_or_missing ->
            model = Ortex.load(path)
            :persistent_term.put(key, {stamp, model})
            {:ok, model}
        end
      else
        {:error, reason} -> {:error, {:tree_model, path, reason}}
      end
    rescue
      e -> {:error, {:tree_model, path, Exception.message(e)}}
    end
  end
end
