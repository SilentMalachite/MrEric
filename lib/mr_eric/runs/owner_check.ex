defmodule MrEric.Runs.OwnerCheck do
  @moduledoc false

  alias MrEric.Runs.Run

  @spec verify(Run.t() | {:error, term()}, binary() | nil) ::
          {:ok, Run.t()} | {:error, :not_owner | term()}
  def verify({:error, reason}, _owner_id), do: {:error, reason}

  def verify(%Run{owner_id: owner_id} = run, owner_id) when is_binary(owner_id) do
    {:ok, run}
  end

  def verify(%Run{}, _other_owner_id), do: {:error, :not_owner}
end
