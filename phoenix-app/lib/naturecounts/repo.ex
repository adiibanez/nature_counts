defmodule Naturecounts.Repo do
  use Ecto.Repo,
    otp_app: :naturecounts,
    adapter: Ecto.Adapters.Postgres
end
