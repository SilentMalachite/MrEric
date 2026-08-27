import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mr_eric, MrEricWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :mr_eric, :openai_req_options, plug: MrEric.OpenAIMock

# Never probe local LLM endpoints during tests; default-provider resolution
# falls back to OpenAI so tests stay deterministic and offline.
config :mr_eric, :provider_health_check, false

# Spec D run limits. The suite starts dozens of runs and, once reaping is in
# place, each finished worker holds its supervisor slot for the grace period.
# Raise the cap so no test is refused, and shorten the grace so workers do not
# accumulate for the whole run — while still leaving room for the
# post-completion `Runs.get_run/1` that `MrEric.Evals.Runner` performs.
config :mr_eric, :run_limits,
  max_concurrent_runs: 64,
  terminal_run_ttl_ms: 5_000
