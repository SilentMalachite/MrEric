defmodule MrEric.Runs.OwnerCheckTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.OwnerCheck
  alias MrEric.Runs.Run

  defp run(owner_id) do
    Run.new("t", owner_id: owner_id, provider: :ollama, model: "m")
  end

  test "verify/2 returns {:ok, run} when owner_id matches" do
    r = run("alice")
    assert {:ok, ^r} = OwnerCheck.verify(r, "alice")
  end

  test "verify/2 returns {:error, :not_owner} when owner_id differs" do
    r = run("alice")
    assert {:error, :not_owner} = OwnerCheck.verify(r, "bob")
  end

  test "verify/2 propagates {:error, reason} unchanged" do
    assert {:error, :not_found} = OwnerCheck.verify({:error, :not_found}, "anything")
    assert {:error, :foo} = OwnerCheck.verify({:error, :foo}, "anything")
  end

  test "verify/2 with nil owner_id on the supplied side returns :not_owner" do
    r = run("alice")
    assert {:error, :not_owner} = OwnerCheck.verify(r, nil)
  end
end
