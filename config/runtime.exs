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
#     PHX_SERVER=true bin/monkey_claw start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :monkey_claw, MonkeyClawWeb.Endpoint, server: true
end

if config_env() != :prod do
  config :monkey_claw, MonkeyClawWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/monkey_claw/monkey_claw.db
      """

  config :monkey_claw, MonkeyClaw.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

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

  signing_salt =
    System.get_env("SIGNING_SALT") ||
      raise """
      environment variable SIGNING_SALT is missing.
      You can generate one by calling: mix phx.gen.secret 32
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :monkey_claw, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  tls_cert = System.get_env("TLS_CERT_PATH") || raise("TLS_CERT_PATH not set")
  tls_key = System.get_env("TLS_KEY_PATH") || raise("TLS_KEY_PATH not set")
  tls_ca = System.get_env("TLS_CA_PATH") || raise("TLS_CA_PATH not set")

  config :monkey_claw, MonkeyClawWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    https: [
      # Bind all interfaces (IPv6 + IPv4)
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("HTTPS_PORT") || "443"),
      cipher_suite: :strong,
      certfile: tls_cert,
      keyfile: tls_key,
      cacertfile: tls_ca,
      # TLS 1.3 only — avoids broader attack surface of 1.2 cipher
      # negotiation and OTP bug #7978 with mTLS dual-version signing
      versions: [:"tlsv1.3"],
      # mTLS: require and verify client certificates
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      depth: 3
    ],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: signing_salt]

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :monkey_claw, MonkeyClaw.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
