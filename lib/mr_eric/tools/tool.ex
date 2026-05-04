defmodule MrEric.Tools.Tool do
  @moduledoc """
  Behaviour for Phase 5A built-in tools.

  Tools receive normalized argument maps with atom keys for known fields. They
  must return plain maps so results can be sanitized before PubSub broadcast.
  """

  @type args :: map()
  @type result :: map()
  @type reason :: atom() | String.t() | term()

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback run(args(), keyword()) :: {:ok, result()} | {:error, reason()}
end
