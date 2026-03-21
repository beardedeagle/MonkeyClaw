defmodule MonkeyClawWeb.Plugs.MTLSAudit do
  @moduledoc """
  Required plug that extracts and audits mTLS client certificate metadata.

  This plug runs on every connection and provides defense-in-depth
  certificate verification at the application layer. The primary
  authentication occurs at the TLS handshake (OTP `:ssl` with
  `verify: :verify_peer` and `fail_if_no_peer_cert: true`), so by
  the time a request reaches this plug the client has already proven
  possession of a valid certificate signed by our CA.

  ## Responsibilities

    * Extract the DER-encoded client certificate from peer data
    * Decode the certificate and extract CN, serial, and fingerprint
    * Assign certificate metadata to `conn.assigns.client_cert`
    * Emit `[:monkey_claw, :mtls, :connection]` telemetry events
    * Log the authenticated connection at `:debug` level

  ## Environment Behavior

    * **Production**: Halts with 403 if no client certificate is present
      (should never happen with correct endpoint config — defense in depth)
    * **Dev/Test**: Assigns `nil` client cert and logs a warning, allowing
      HTTP-only development without certificates

  ## Assigned Metadata

  On successful extraction, `conn.assigns.client_cert` contains:

      %{
        cn: "MonkeyClaw Owner",
        serial: 123456789,
        fingerprint: <<sha256_bytes::binary-32>>
      }
  """

  @behaviour Plug

  require Logger
  require Record

  # Extract OTP certificate record fields at compile time from public_key.hrl.
  # This is safe across OTP versions — field names come from the .hrl.
  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :attribute_type_and_value,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl")
  )

  # OID for commonName (2.5.4.3)
  @oid_common_name {2, 5, 4, 3}

  @type cert_metadata :: %{
          cn: String.t(),
          serial: non_neg_integer(),
          fingerprint: <<_::256>>
        }

  # --- Plug callbacks ---

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts) do
    Keyword.put_new_lazy(opts, :env, fn ->
      Application.get_env(:monkey_claw, :env, :prod)
    end)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    peer_data = Plug.Conn.get_peer_data(conn)

    case Map.get(peer_data, :ssl_cert) do
      nil ->
        handle_missing_cert(conn, Keyword.fetch!(opts, :env))

      der_cert when is_binary(der_cert) ->
        handle_cert(conn, der_cert)
    end
  end

  # --- Internal ---

  defp handle_cert(conn, der_cert) do
    case extract_metadata(der_cert) do
      {:ok, metadata} ->
        short_fp = metadata.fingerprint |> binary_part(0, 8) |> Base.encode16(case: :lower)

        :telemetry.execute(
          [:monkey_claw, :mtls, :connection],
          %{count: 1},
          %{cn: metadata.cn, fingerprint: metadata.fingerprint, remote_ip: conn.remote_ip}
        )

        Logger.debug("mTLS connection from CN=#{metadata.cn} fp=#{short_fp}")

        Plug.Conn.assign(conn, :client_cert, metadata)

      {:error, reason} ->
        Logger.error("mTLS certificate decode failed: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "Certificate decode error")
        |> Plug.Conn.halt()
    end
  end

  defp handle_missing_cert(conn, env) do
    if env == :prod do
      :telemetry.execute(
        [:monkey_claw, :mtls, :connection],
        %{count: 1},
        %{cn: nil, fingerprint: nil, remote_ip: conn.remote_ip, rejected: true}
      )

      Logger.warning("mTLS: no client certificate in production — rejecting")

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Client certificate required")
      |> Plug.Conn.halt()
    else
      Logger.warning("mTLS: no client certificate (dev/test mode — allowing)")
      Plug.Conn.assign(conn, :client_cert, nil)
    end
  end

  @doc false
  @spec extract_metadata(binary()) :: {:ok, cert_metadata()} | {:error, term()}
  def extract_metadata(der_cert) do
    otp_cert = :public_key.pkix_decode_cert(der_cert, :otp)
    tbs = otp_certificate(otp_cert, :tbsCertificate)
    serial = otp_tbs_certificate(tbs, :serialNumber)
    cn = extract_common_name(otp_tbs_certificate(tbs, :subject))
    fingerprint = :crypto.hash(:sha256, der_cert)

    {:ok, %{cn: cn, serial: serial, fingerprint: fingerprint}}
  rescue
    e -> {:error, e}
  end

  defp extract_common_name({:rdnSequence, rdn_sets}) do
    rdn_sets
    |> List.flatten()
    |> Enum.find_value("unknown", &extract_cn_attr/1)
  end

  defp extract_common_name(_), do: "unknown"

  defp extract_cn_attr(attr) do
    case attribute_type_and_value(attr, :type) do
      @oid_common_name -> decode_cn_value(attribute_type_and_value(attr, :value))
      _ -> nil
    end
  end

  # OTP versions encode the CN value differently:
  # - OTP 28+: {:utf8String, "name"} (PKIX1Explicit-2009 CHOICE type)
  # - Earlier: raw binary or charlist
  defp decode_cn_value({:utf8String, name}) when is_binary(name), do: name
  defp decode_cn_value({:utf8String, name}) when is_list(name), do: List.to_string(name)
  defp decode_cn_value({:printableString, name}) when is_binary(name), do: name
  defp decode_cn_value({:printableString, name}) when is_list(name), do: List.to_string(name)
  defp decode_cn_value(name) when is_binary(name), do: name
  defp decode_cn_value(name) when is_list(name), do: List.to_string(name)
  defp decode_cn_value(_), do: "unknown"
end
