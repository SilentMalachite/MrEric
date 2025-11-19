import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mr_eric start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mr_eric, MrEricWeb.Endpoint, server: true
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :mr_eric, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mr_eric, MrEricWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Ensure the appropriate AI provider API key is present in production
  provider = (Application.get_env(:mr_eric, :ai_provider) || System.get_env("AI_PROVIDER") || "openai") |> String.downcase()

  case provider do
    "openrouter" ->
      if is_nil(System.get_env("OPENROUTER_API_KEY")) do
        raise "environment variable OPENROUTER_API_KEY is missing. Set it to a valid OpenRouter API key in production."
      end

    "grok" ->
      if is_nil(System.get_env("GROK_API_KEY")) && is_nil(System.get_env("XAI_API_KEY")) do
        raise "environment variable GROK_API_KEY (or XAI_API_KEY) is missing. Set it to a valid xAI Grok API key in production."
      end

    "xai" ->
      if is_nil(System.get_env("GROK_API_KEY")) && is_nil(System.get_env("XAI_API_KEY")) do
        raise "environment variable GROK_API_KEY (or XAI_API_KEY) is missing. Set it to a valid xAI Grok API key in production."
      end

    # Local providers (no API key required by default)
    "ollama" ->
      :ok

    "lmstudio" ->
      :ok

    "llstudio" ->
      :ok

    _ ->
      if is_nil(System.get_env("OPENAI_API_KEY")) do
        raise "environment variable OPENAI_API_KEY is missing. Set it to a valid OpenAI API key in production."
      end
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mr_eric, MrEricWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mr_eric, MrEricWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

end
