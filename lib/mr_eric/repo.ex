defmodule MrEric.Repo do
  use Ecto.Repo,
    otp_app: :mr_eric,
    adapter: Ecto.Adapters.Postgres
end
