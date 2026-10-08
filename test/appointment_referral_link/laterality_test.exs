defmodule AppointmentReferralLink.LateralityTest do
  use ExUnit.Case, async: true

  alias AppointmentReferralLink.Laterality

  describe "from_text/1" do
    test "reads right and left tokens" do
      assert Laterality.from_text("Right knee locking") == :right
      assert Laterality.from_text("rt knee pain") == :right
      assert Laterality.from_text("LT knee") == :left
      assert Laterality.from_text("left-knee pain") == :left
    end

    test "reads bilateral tokens and both sides as bilateral" do
      assert Laterality.from_text("bilateral knee pain") == :bilateral
      assert Laterality.from_text("bilat knees") == :bilateral
      assert Laterality.from_text("both knees") == :bilateral
      assert Laterality.from_text("right and left knee") == :bilateral
    end

    test "does not match inside other words" do
      assert Laterality.from_text("brightness and lethargy") == nil
      assert Laterality.from_text("multiple lesions") == nil
    end

    test "nil and no tokens give nil" do
      assert Laterality.from_text(nil) == nil
      assert Laterality.from_text("knee locking") == nil
    end
  end

  test "fill/2 only fills nil" do
    assert Laterality.fill(nil, "lt knee") == :left
    assert Laterality.fill(:right, "lt knee") == :right
    assert Laterality.fill(nil, nil) == nil
  end

  test "compare/2" do
    assert Laterality.compare(:right, :right) == :agree
    assert Laterality.compare(:right, :bilateral) == :agree
    assert Laterality.compare(:bilateral, :left) == :agree
    assert Laterality.compare(:right, :left) == :conflict
    assert Laterality.compare(nil, :left) == :unknown
    assert Laterality.compare(:right, nil) == :unknown
  end
end
