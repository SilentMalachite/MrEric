defmodule MrEric.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.Registry

  test "lists the Phase 5A built-in tools" do
    assert Registry.names() == [
             :file_read,
             :file_write_proposal,
             :shell_command,
             :git_status,
             :git_diff
           ]

    assert Enum.all?(Registry.list(), &Map.has_key?(&1, :schema))
  end

  test "fetches tools by atom or string without creating atoms" do
    assert {:ok, MrEric.Tools.FileRead} = Registry.fetch(:file_read)
    assert {:ok, MrEric.Tools.FileRead} = Registry.fetch("file_read")
    assert {:error, :unknown_tool} = Registry.fetch("not_a_tool")
  end
end
