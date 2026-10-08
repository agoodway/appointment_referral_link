defmodule AppointmentReferralLink.OntologyTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Ontology

  setup do
    {:ok, ontology} = Ontology.load([Ontology.default_path()])
    %{ontology: ontology}
  end

  test "same canonical part or synonym is exact", %{ontology: o} do
    assert Ontology.match(o, "knee", "knee") == :exact
    assert Ontology.match(o, " Knee ", "knee joint") == :exact
    assert Ontology.match(o, "medial  knee", "Medial Knee") == :exact
  end

  test "a child of the same part is related", %{ontology: o} do
    assert Ontology.match(o, "knee", "medial knee") == :related
    assert Ontology.match(o, "patella", "knee") == :related
    assert Ontology.match(o, "patella", "meniscus") == :related
  end

  test "different parts mismatch", %{ontology: o} do
    assert Ontology.match(o, "knee", "shoulder") == :mismatch
    assert Ontology.match(o, "medial knee", "rotator cuff") == :mismatch
  end

  test "nil or unknown terms are unknown, never mismatch", %{ontology: o} do
    assert Ontology.match(o, nil, "knee") == :unknown
    assert Ontology.match(o, "knee", nil) == :unknown
    assert Ontology.match(o, "knee", "zygomatic arch") == :unknown
  end

  @tag :tmp_dir
  test "a site file extends the shipped ontology", %{tmp_dir: dir} do
    path = Path.join(dir, "site.json")

    File.write!(path, ~s({"format": 1, "parts": {"knee": {"children": ["popliteal fossa"]},
      "jaw": {"synonyms": ["tmj"]}}}))

    {:ok, o} = Ontology.load([Ontology.default_path(), path])
    assert Ontology.match(o, "knee", "popliteal fossa") == :related
    assert Ontology.match(o, "knee", "medial knee") == :related
    assert Ontology.match(o, "jaw", "tmj") == :exact
  end

  @tag :tmp_dir
  test "a missing or malformed file is an error", %{tmp_dir: dir} do
    bad = Path.join(dir, "bad.json")
    File.write!(bad, ~s({"format": 2}))

    assert {:error, {:ontology, _, _}} = Ontology.load([Path.join(dir, "nope.json")])
    assert {:error, {:ontology, ^bad, :invalid_format}} = Ontology.load([bad])
  end
end
