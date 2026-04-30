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
#     PHX_SERVER=true bin/diogramos start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :diogramos, DiogramosWeb.Endpoint, server: true
end

config :diogramos, DiogramosWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Prefer discrete POSTGRES_* env vars (composes safely even when the
  # password contains URL-significant characters like @ / : + & — which
  # is common with StackGres / KubeDB-generated passwords). Fall back to
  # DATABASE_URL when those aren't present.
  cond do
    System.get_env("POSTGRES_HOST") ->
      config :diogramos, Diogramos.Repo,
        hostname: System.get_env("POSTGRES_HOST"),
        port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
        username:
          System.get_env("POSTGRES_USER") ||
            raise("POSTGRES_USER is required when POSTGRES_HOST is set"),
        password:
          System.get_env("POSTGRES_PASSWORD") ||
            raise("POSTGRES_PASSWORD is required when POSTGRES_HOST is set"),
        database: System.get_env("POSTGRES_DB") || "diogramos",
        pool_size: pool_size,
        socket_options: maybe_ipv6

    System.get_env("DATABASE_URL") ->
      config :diogramos, Diogramos.Repo,
        url: System.get_env("DATABASE_URL"),
        pool_size: pool_size,
        socket_options: maybe_ipv6

    true ->
      raise """
      Database configuration missing. Set either:
        - POSTGRES_HOST + POSTGRES_USER + POSTGRES_PASSWORD (preferred), or
        - DATABASE_URL (e.g. ecto://USER:PASS@HOST/DATABASE)
      """
  end

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

  config :diogramos, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # libcluster — Kubernetes endpoints lookup against the headless
  # service we deploy alongside the app. RBAC (pods + endpoints) is
  # granted to the `diogramos` ServiceAccount in app.yml.
  config :libcluster,
    topologies: [
      diogramos: [
        strategy: Cluster.Strategy.Kubernetes,
        config: [
          mode: :ip,
          # Both keys are required by libcluster 3.5 even in :endpoints
          # lookup mode — it filters endpoints by selector.
          kubernetes_selector: "name=diogramos",
          kubernetes_service_name: "diogramos-headless",
          kubernetes_node_basename: "diogramos",
          kubernetes_namespace: "diogramos",
          polling_interval: 10_000
        ]
      ]
    ]

  # Sentry: only emits when DSN is non-empty, so the secret can be left
  # blank in environments where reporting is off.
  config :sentry,
    dsn: System.get_env("SENTRY_DSN"),
    environment_name: :prod,
    release: System.get_env("APP_VERSION") || System.get_env("CI_COMMIT_SHA")

  # Mailer adapter selection:
  #
  #   * SMTP_RELAY set  → Swoosh.Adapters.SMTP (gen_smtp)
  #   * otherwise       → Swoosh.Adapters.Logger
  #
  # The Logger adapter doesn't actually send mail — it logs the
  # rendered email at :info — but it gets us off Swoosh.Adapters.Local,
  # which is what the login page checks for to show the dev-mailbox
  # banner.
  smtp_tri = fn var, default ->
    case System.get_env(var, default) do
      v when v in ~w(always if_available never) -> String.to_existing_atom(v)
      other -> raise "#{var} must be one of always|if_available|never, got: #{inspect(other)}"
    end
  end

  mailer_opts =
    if relay = System.get_env("SMTP_RELAY") do
      [
        adapter: Swoosh.Adapters.SMTP,
        relay: relay,
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        tls: smtp_tri.("SMTP_TLS", "if_available"),
        ssl: System.get_env("SMTP_SSL", "false") == "true",
        auth: smtp_tri.("SMTP_AUTH", "if_available"),
        retries: 1,
        no_mx_lookups: false
      ]
    else
      [adapter: Swoosh.Adapters.Logger, level: :info]
    end

  config :diogramos, Diogramos.Mailer, mailer_opts

  config :diogramos, Diogramos.Mailer,
    from_name: System.get_env("MAIL_FROM_NAME", "Diogramos"),
    from_address: System.get_env("MAIL_FROM_ADDRESS") || "noreply@#{host}"

  config :diogramos, DiogramosWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Accept both http and https origins for the configured host. The
    # `//host` form matches any scheme/port. Without this the LiveView
    # WebSocket upgrade is rejected silently when the proxy forwards a
    # subtly-different Origin header (no Logger event, nothing in Sentry).
    check_origin: ["//#{host}", "https://#{host}"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :diogramos, DiogramosWeb.Endpoint,
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
  #     config :diogramos, DiogramosWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :diogramos, Diogramos.Mailer,
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
