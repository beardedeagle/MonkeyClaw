defmodule MonkeyClaw.CertGen do
  @moduledoc """
  Generates a complete set of mTLS certificates for MonkeyClaw.

  Creates a self-signed CA, a server certificate with SANs, a client
  certificate, and a PKCS#12 bundle for browser import — all using
  pure Elixir via the `x509` library.

  This module contains the certificate generation logic independent of
  Mix, so it can be called from Mix tasks during development or from
  the runtime CLI in releases.

  ## Options

    * `:sans` — list of Subject Alternative Names (DNS names or IP
      addresses). Default: `["localhost", "127.0.0.1", "::1"]`
    * `:output_dir` — directory to write certificates. Default: `"priv/cert"`
    * `:validity_days` — validity period in days for leaf certs.
      Default: 365 (CA always uses 3650)
    * `:password` — password for the PKCS#12 bundle. Default: random
    * `:force` — overwrite existing certificates. Default: `false`

  ## Generated Files

    * `ca.pem` — CA certificate (PEM)
    * `ca-key.pem` — CA private key (PEM, mode 0600)
    * `server.pem` — Server certificate (PEM)
    * `server-key.pem` — Server private key (PEM, mode 0600)
    * `client.pem` — Client certificate (PEM)
    * `client-key.pem` — Client private key (PEM, mode 0600)
    * `client.p12` — Client PKCS#12 bundle for browser import (mode 0600)

  ## Return Value

  On success, returns `{:ok, result}` where result is a map containing:

      %{
        output_dir: "priv/cert",
        password: "generated_or_provided_password",
        sans: ["localhost", "127.0.0.1", "::1"],
        validity_days: 365,
        ca_validity_days: 3650,
        files: ["ca.pem", "ca-key.pem", ...]
      }

  Returns `{:error, {:certs_exist, output_dir}}` if certificates already
  exist and `:force` is not set.
  """

  alias MonkeyClaw.Crypto.PKCS12
  alias X509.Certificate.Extension, as: CertExtension

  require Logger
  require Record

  Record.defrecordp(
    :ec_private_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  @default_sans ["localhost", "127.0.0.1", "::1"]
  @default_output_dir "priv/cert"
  @default_validity_days 365
  @ca_validity_days 3650
  @default_password_length 24
  # secp256r1 private key must be exactly 32 bytes
  @ec_key_size 32

  @expected_files ~w(ca.pem ca-key.pem server.pem server-key.pem client.pem client-key.pem client.p12)

  @type result :: %{
          output_dir: String.t(),
          password: String.t(),
          sans: [String.t()],
          validity_days: pos_integer(),
          ca_validity_days: pos_integer(),
          files: [String.t()]
        }

  @doc """
  Generates a full set of mTLS certificates.

  See module documentation for available options and return values.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, {:certs_exist, String.t()}}
  def run(opts \\ []) do
    sans = Keyword.get(opts, :sans, @default_sans)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    validity_days = Keyword.get(opts, :validity_days, @default_validity_days)

    password =
      Keyword.get_lazy(opts, :password, fn ->
        :crypto.strong_rand_bytes(@default_password_length) |> Base.url_encode64()
      end)

    force? = Keyword.get(opts, :force, false)

    if not force? and certs_exist?(output_dir) do
      {:error, {:certs_exist, output_dir}}
    else
      generate_all(sans, output_dir, validity_days, password)
    end
  end

  # --- Generation Pipeline ---

  defp generate_all(sans, output_dir, validity_days, password) do
    Logger.info("Generating mTLS certificates...")
    Logger.info("  SANs: #{Enum.join(sans, ", ")}")
    Logger.info("  Output: #{output_dir}/")
    Logger.info("  Validity: #{validity_days} days (CA: #{@ca_validity_days} days)")

    File.mkdir_p!(output_dir)

    # Generate CA
    ca_key = generate_ec_key()
    ca_cert = generate_ca_cert(ca_key)

    # Generate server cert with SANs
    server_key = generate_ec_key()
    san_entries = build_san_entries(sans)
    server_cert = generate_server_cert(server_key, ca_cert, ca_key, san_entries, validity_days)

    # Generate client cert
    client_key = generate_ec_key()
    client_cert = generate_client_cert(client_key, ca_cert, ca_key, validity_days)

    # Generate PKCS#12 bundle
    client_cert_der = X509.Certificate.to_der(client_cert)
    {:ok, p12_bundle} = PKCS12.encode(client_key, [client_cert_der], password)

    # Write all files
    write_cert_files(output_dir, %{
      ca_key: ca_key,
      ca_cert: ca_cert,
      server_key: server_key,
      server_cert: server_cert,
      client_key: client_key,
      client_cert: client_cert,
      p12_bundle: p12_bundle
    })

    # Ensure .gitignore covers the output directory
    ensure_gitignore(output_dir)

    {:ok,
     %{
       output_dir: output_dir,
       password: password,
       sans: sans,
       validity_days: validity_days,
       ca_validity_days: @ca_validity_days,
       files: @expected_files
     }}
  end

  # --- Key Generation ---

  defp generate_ec_key do
    key = X509.PrivateKey.new_ec(:secp256r1)
    normalize_ec_key(key)
  end

  # OTP bug #4861: secp256r1 keys can occasionally be 31 bytes
  # due to leading zero stripping. Pad to 32 bytes.
  defp normalize_ec_key(key) do
    private_bytes = ec_private_key(key, :privateKey)

    case byte_size(private_bytes) do
      @ec_key_size ->
        key

      short when short < @ec_key_size ->
        padding = @ec_key_size - short
        padded = <<0::size(padding)-unit(8), private_bytes::binary>>
        ec_private_key(key, privateKey: padded)
    end
  end

  # --- Certificate Generation ---

  defp generate_ca_cert(ca_key) do
    X509.Certificate.self_signed(ca_key, "/CN=MonkeyClaw CA",
      template: :root_ca,
      validity: @ca_validity_days
    )
  end

  defp generate_server_cert(server_key, ca_cert, ca_key, san_entries, validity_days) do
    server_pub = X509.PublicKey.derive(server_key)

    X509.Certificate.new(server_pub, "/CN=MonkeyClaw Server", ca_cert, ca_key,
      template: :server,
      validity: validity_days,
      extensions: [
        subject_alt_name: CertExtension.subject_alt_name(san_entries)
      ]
    )
  end

  defp generate_client_cert(client_key, ca_cert, ca_key, validity_days) do
    client_pub = X509.PublicKey.derive(client_key)

    X509.Certificate.new(client_pub, "/CN=MonkeyClaw Owner", ca_cert, ca_key,
      template: :server,
      validity: validity_days,
      extensions: [
        key_usage: CertExtension.key_usage([:digitalSignature]),
        ext_key_usage: CertExtension.ext_key_usage([:clientAuth])
      ]
    )
  end

  # --- SAN Handling ---

  defp build_san_entries(sans) do
    Enum.map(sans, fn san ->
      case parse_ip(san) do
        {:ok, ip_binary} -> {:iPAddress, ip_binary}
        :error -> san
      end
    end)
  end

  # Parse a string as an IP address and pack into raw bytes for ASN.1
  # GeneralName encoding. Returns {:ok, binary} for valid IPs (4 bytes
  # for IPv4, 16 bytes for IPv6) or :error for DNS names.
  defp parse_ip(san) do
    case :inet.parse_address(String.to_charlist(san)) do
      {:ok, {a, b, c, d}} ->
        {:ok, <<a, b, c, d>>}

      {:ok, {a, b, c, d, e, f, g, h}} ->
        {:ok, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}

      {:error, _} ->
        :error
    end
  end

  # --- File Writing ---

  defp write_cert_files(output_dir, certs) do
    # PEM files — certificates (world-readable)
    write_file(output_dir, "ca.pem", X509.Certificate.to_pem(certs.ca_cert))
    write_file(output_dir, "server.pem", X509.Certificate.to_pem(certs.server_cert))
    write_file(output_dir, "client.pem", X509.Certificate.to_pem(certs.client_cert))

    # PEM files — private keys (owner-only)
    write_private_file(output_dir, "ca-key.pem", X509.PrivateKey.to_pem(certs.ca_key))
    write_private_file(output_dir, "server-key.pem", X509.PrivateKey.to_pem(certs.server_key))
    write_private_file(output_dir, "client-key.pem", X509.PrivateKey.to_pem(certs.client_key))

    # PKCS#12 bundle (owner-only)
    write_private_file(output_dir, "client.p12", certs.p12_bundle)
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    Logger.info("  Created #{path}")
  end

  defp write_private_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o600)
    Logger.info("  Created #{path} (mode 0600)")
  end

  # --- Utility ---

  defp certs_exist?(output_dir) do
    Path.join(output_dir, "ca.pem") |> File.exists?()
  end

  defp ensure_gitignore(output_dir) do
    gitignore_path = ".gitignore"

    # Only manage .gitignore for relative paths within the project.
    # Absolute paths (e.g. System.tmp_dir!() in tests) are outside the
    # project and must not pollute .gitignore.
    if Path.type(output_dir) == :relative and File.exists?(gitignore_path) do
      entry = "/#{output_dir}/"
      contents = File.read!(gitignore_path)

      unless String.contains?(contents, entry) do
        File.write!(gitignore_path, contents <> "\n#{entry}\n")
        Logger.info("  Added #{entry} to .gitignore")
      end
    end
  end
end
