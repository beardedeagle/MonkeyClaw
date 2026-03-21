defmodule Mix.Tasks.MonkeyClaw.Gen.Certs do
  @shortdoc "Generate mTLS certificates for MonkeyClaw"

  @moduledoc """
  Generates a complete set of mTLS certificates for MonkeyClaw.

  Creates a self-signed CA, a server certificate with SANs, a client
  certificate, and a PKCS#12 bundle for browser import — all using
  pure Elixir with no external dependencies.

  This is a development convenience wrapper around `MonkeyClaw.CertGen`.
  In releases, use the runtime CLI instead.

  ## Usage

      mix monkey_claw.gen.certs
      mix monkey_claw.gen.certs --san my.domain --san 10.0.0.5
      mix monkey_claw.gen.certs --output-dir /etc/monkey_claw/cert
      mix monkey_claw.gen.certs --force

  ## Options

    * `--san` — Subject Alternative Name (repeatable). Accepts DNS names
      and IP addresses. Default: `localhost`, `127.0.0.1`, `::1`
    * `--output-dir` — Directory to write certificates. Default: `priv/cert/`
    * `--validity-days` — Validity period in days for leaf certs.
      Default: 365 (CA always uses 3650)
    * `--password` — Password for the PKCS#12 bundle. Default: random
    * `--force` — Overwrite existing certificates without prompting

  ## Generated Files

    * `ca.pem` — CA certificate (PEM)
    * `ca-key.pem` — CA private key (PEM, mode 0600)
    * `server.pem` — Server certificate (PEM)
    * `server-key.pem` — Server private key (PEM, mode 0600)
    * `client.pem` — Client certificate (PEM)
    * `client-key.pem` — Client private key (PEM, mode 0600)
    * `client.p12` — Client PKCS#12 bundle for browser import (mode 0600)

  ## Browser Import Instructions

  After generating certificates, import `client.p12` into your browser:

    * **Chrome**: Settings → Privacy and Security → Security → Manage Certificates
    * **Firefox**: Settings → Privacy & Security → Certificates → View Certificates
    * **Safari**: Double-click the .p12 file to add to Keychain Access
    * **iOS**: AirDrop or email the .p12 file, then install the profile
    * **Android**: Settings → Security → Install from storage
  """

  use Mix.Task

  @switches [
    san: :keep,
    output_dir: :string,
    validity_days: :integer,
    password: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

    cert_opts = to_cert_gen_opts(opts)

    case MonkeyClaw.CertGen.run(cert_opts) do
      {:ok, result} ->
        print_instructions(result)

      {:error, {:certs_exist, dir}} ->
        Mix.raise("""
        Certificates already exist in #{dir}/
        Use --force to overwrite existing certificates.
        """)
    end
  end

  # Convert CLI switches to CertGen keyword opts.
  # Maps --san (repeatable) to :sans list and passes through the rest.
  defp to_cert_gen_opts(opts) do
    cert_opts = []

    cert_opts =
      case Keyword.get_values(opts, :san) do
        [] -> cert_opts
        sans -> Keyword.put(cert_opts, :sans, sans)
      end

    cert_opts
    |> maybe_put(opts, :output_dir)
    |> maybe_put(opts, :validity_days)
    |> maybe_put(opts, :password)
    |> maybe_put(opts, :force)
  end

  defp maybe_put(cert_opts, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(cert_opts, key, value)
      :error -> cert_opts
    end
  end

  defp print_instructions(result) do
    Mix.shell().info("""

    mTLS certificates generated successfully!

    To use in development, update config/dev.exs:

        https: [
          port: 4001,
          cipher_suite: :strong,
          versions: [:"tlsv1.3"],
          certfile: "#{result.output_dir}/server.pem",
          keyfile: "#{result.output_dir}/server-key.pem",
          cacertfile: "#{result.output_dir}/ca.pem",
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          depth: 3
        ]

    Import the client certificate into your browser:

      #{result.output_dir}/client.p12 (password: #{result.password})

      Chrome:   Settings > Privacy and Security > Security > Manage Certificates
      Firefox:  Settings > Privacy & Security > Certificates > View Certificates
      Safari:   Double-click client.p12 to add to Keychain Access
      iOS:      AirDrop or email the .p12 file, then install the profile
      Android:  Settings > Security > Install from storage

    For production, set these environment variables:

      TLS_CERT_PATH=#{result.output_dir}/server.pem
      TLS_KEY_PATH=#{result.output_dir}/server-key.pem
      TLS_CA_PATH=#{result.output_dir}/ca.pem
    """)
  end
end
