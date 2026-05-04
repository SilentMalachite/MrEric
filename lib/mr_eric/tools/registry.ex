defmodule MrEric.Tools.Registry do
  @moduledoc """
  Registry for built-in Phase 5A tools.
  """

  @tools [
    MrEric.Tools.FileRead,
    MrEric.Tools.FileWriteProposal,
    MrEric.Tools.ShellCommand,
    MrEric.Tools.GitStatus,
    MrEric.Tools.GitDiff
  ]

  def all, do: @tools

  def list do
    Enum.map(@tools, fn tool ->
      %{
        name: tool.name(),
        description: tool.description(),
        schema: tool.schema()
      }
    end)
  end

  def names, do: Enum.map(@tools, & &1.name())

  def fetch(name) do
    case get(name) do
      nil -> {:error, :unknown_tool}
      tool -> {:ok, tool}
    end
  end

  def get(name) do
    normalized = normalize_name(name)
    Enum.find(@tools, &(Atom.to_string(&1.name()) == normalized))
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(_name), do: ""
end
