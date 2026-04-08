defmodule MonkeyClaw.AgentBridge.Backend.BeamAgent do
  @moduledoc """
  Production backend adapter wrapping the BeamAgent runtime.

  Session lifecycle, queries, threads, and checkpoints delegate
  directly to `BeamAgent` and `BeamAgent.Threads`.

  Model listing uses beam_agent's own session-based catalog:
  checks `BeamAgent.Auth.status/1` for authentication, starts a
  temporary session to query `BeamAgent.Catalog.supported_models/1`,
  normalizes the results to `model_attrs` shape, and stops the
  session. No direct HTTP calls to provider APIs.

  This is the default backend used when no `:backend` key is
  present in the session config.
  """

  @behaviour MonkeyClaw.AgentBridge.Backend

  @impl true
  def start_session(opts), do: BeamAgent.start_session(opts)

  @impl true
  def stop_session(pid), do: BeamAgent.stop(pid)

  @impl true
  def query(pid, prompt, params) when map_size(params) == 0 do
    BeamAgent.query(pid, prompt)
  end

  def query(pid, prompt, params) do
    BeamAgent.query(pid, prompt, params)
  end

  @impl true
  def stream(pid, prompt, params) do
    {:ok, BeamAgent.stream(pid, prompt, params)}
  end

  # BeamAgent.set_model/2 and BeamAgent.set_permission_mode/2 are not yet
  # exported by beam_agent_ex. Suppress Dialyzer call_to_missing with
  # @dialyzer annotations; the function_exported?/3 guard ensures runtime
  # safety until the API is available.

  @dialyzer {:nowarn_function, set_model: 2}
  @impl true
  def set_model(pid, model) do
    if function_exported?(BeamAgent, :set_model, 2) do
      BeamAgent.set_model(pid, model)
    else
      {:error, :not_supported}
    end
  end

  @dialyzer {:nowarn_function, set_permission_mode: 2}
  @impl true
  def set_permission_mode(pid, mode) do
    if function_exported?(BeamAgent, :set_permission_mode, 2) do
      BeamAgent.set_permission_mode(pid, mode)
    else
      {:error, :not_supported}
    end
  end

  @impl true
  def session_info(pid), do: BeamAgent.session_info(pid)

  @impl true
  def event_subscribe(pid), do: BeamAgent.event_subscribe(pid)

  @impl true
  def receive_event(pid, ref, timeout), do: BeamAgent.receive_event(pid, ref, timeout)

  @impl true
  def event_unsubscribe(pid, ref), do: BeamAgent.event_unsubscribe(pid, ref)

  @impl true
  def thread_start(pid, opts), do: BeamAgent.Threads.thread_start(pid, opts)

  @impl true
  def thread_resume(pid, thread_id), do: BeamAgent.Threads.thread_resume(pid, thread_id)

  @impl true
  def thread_list(pid), do: BeamAgent.Threads.thread_list(pid)

  # ── Model Listing ───────────────────────────────────────────

  # Known beam_agent backends for validation and normalization.
  @known_backends ~w(claude codex copilot opencode gemini)a

  @dialyzer {:nowarn_function, list_models: 1}
  @impl true
  def list_models(opts) when is_map(opts) do
    # This adapter authenticates via CLI auth status, not vault secrets.
    # Opts like :workspace_id and :secret_name are defined in the
    # behaviour type for adapters that use direct API key auth, but
    # BeamAgent session startup handles auth internally — only :backend
    # is consumed here.
    backend = Map.get(opts, :backend)

    with {:ok, backend_atom} <- normalize_backend(backend),
         {:ok, %{authenticated: true}} <- BeamAgent.Auth.status(backend_atom) do
      list_models_via_session(backend_atom)
    else
      {:ok, %{authenticated: false}} ->
        {:error, :not_authenticated}

      {:error, _} = error ->
        error
    end
  end

  # Start a temporary session, wait for the CLI init handshake to
  # complete, query the backend's model catalog, and stop.
  #
  # start_session/1 returns {:ok, pid} before the session state machine
  # reaches :ready — the CLI init handshake runs asynchronously.
  # supported_models/1 reads from init_response, which is only populated
  # once the handshake completes. await_session_ready/2 polls health/1
  # to gate the catalog query.
  #
  # The 15s readiness timeout is well within ModelRegistry's 30s probe
  # deadline.
  @spec list_models_via_session(atom()) :: {:ok, [map()]} | {:error, term()}
  defp list_models_via_session(backend_atom) do
    provider = backend_to_provider(backend_atom)

    case BeamAgent.start_session(%{backend: backend_atom}) do
      {:ok, session} ->
        try do
          with :ok <- await_session_ready(session, 15_000) do
            case BeamAgent.Catalog.supported_models(session) do
              {:ok, models} when is_list(models) ->
                {:ok, Enum.map(models, &normalize_model(&1, provider))}

              {:error, _} = error ->
                error
            end
          end
        after
          BeamAgent.stop(session)
        end

      {:error, _} = error ->
        error
    end
  end

  # Poll BeamAgent.health/1 until the session reaches :ready state,
  # indicating the CLI init handshake has completed and init_response
  # is populated with the backend's model catalog.
  #
  # Returns :ok when ready, {:error, :session_not_ready} on timeout or
  # terminal state (:error, :unknown).
  @poll_interval_ms 100
  @spec await_session_ready(pid(), integer()) :: :ok | {:error, :session_not_ready}
  defp await_session_ready(_session, remaining_ms) when remaining_ms <= 0 do
    {:error, :session_not_ready}
  end

  defp await_session_ready(session, remaining_ms) do
    case BeamAgent.health(session) do
      :ready ->
        :ok

      state when state in [:connecting, :initializing] ->
        Process.sleep(@poll_interval_ms)
        await_session_ready(session, remaining_ms - @poll_interval_ms)

      _terminal ->
        {:error, :session_not_ready}
    end
  end

  # Validate and normalize the backend identifier to a known atom.
  # Accepts atoms, binaries, and strings. Returns {:error, ...} for
  # unrecognized backends so the probe reports a clear failure rather
  # than crashing.
  @spec normalize_backend(term()) :: {:ok, atom()} | {:error, {:unknown_backend, term()}}
  defp normalize_backend(backend) when is_atom(backend) and backend in @known_backends,
    do: {:ok, backend}

  defp normalize_backend(backend) when is_binary(backend) do
    atom = String.to_existing_atom(backend)
    if atom in @known_backends, do: {:ok, atom}, else: {:error, {:unknown_backend, backend}}
  rescue
    ArgumentError -> {:error, {:unknown_backend, backend}}
  end

  defp normalize_backend(nil), do: {:error, :backend_required}
  defp normalize_backend(other), do: {:error, {:unknown_backend, other}}

  # Map MonkeyClaw backend atoms to their upstream provider string.
  # Single source of truth for the :provider field in model_attrs.
  @dialyzer {:nowarn_function, backend_to_provider: 1}
  @spec backend_to_provider(atom()) :: String.t()
  defp backend_to_provider(:claude), do: "anthropic"
  defp backend_to_provider(:codex), do: "openai"
  defp backend_to_provider(:gemini), do: "google"
  defp backend_to_provider(:opencode), do: "anthropic"
  defp backend_to_provider(:copilot), do: "github_copilot"
  defp backend_to_provider(other), do: Atom.to_string(other)

  # Normalize a beam_agent model entry (binary or atom keys from the
  # CLI init handshake JSON) into the model_attrs shape expected by
  # CachedModel.changeset/2.
  @dialyzer {:nowarn_function, normalize_model: 2}
  @spec normalize_model(map() | binary(), String.t()) :: map()
  defp normalize_model(model_id, provider) when is_binary(model_id) do
    %{provider: provider, model_id: model_id, display_name: model_id, capabilities: %{}}
  end

  defp normalize_model(model, provider) when is_map(model) do
    model_id =
      coalesce_key(
        model,
        [:model_id, "model_id", :model, "model", :name, "name", :id, "id"],
        "unknown"
      )

    %{
      provider: provider,
      model_id: to_string(model_id),
      display_name:
        to_string(coalesce_key(model, [:display_name, "display_name", :name, "name"], model_id)),
      capabilities: coalesce_key(model, [:capabilities, "capabilities"], %{})
    }
  end

  # Return the first non-nil value found for any of the candidate keys,
  # or the default when none match.
  @spec coalesce_key(map(), [atom() | String.t()], term()) :: term()
  defp coalesce_key(map, keys, default) do
    Enum.reduce_while(keys, default, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, value} when not is_nil(value) -> {:halt, value}
        _ -> {:cont, acc}
      end
    end)
  end

  # ── Checkpoint Operations ────────────────────────────────────

  @impl true
  def checkpoint_save(pid, label, file_paths) do
    with {:ok, info} <- BeamAgent.session_info(pid) do
      uuid = "#{label}-#{:erlang.unique_integer([:positive, :monotonic])}"

      case BeamAgent.Checkpoint.snapshot(info.session_id, uuid, file_paths) do
        {:ok, _cp} -> {:ok, uuid}
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def checkpoint_rewind(pid, checkpoint_id) do
    with {:ok, info} <- BeamAgent.session_info(pid) do
      BeamAgent.Checkpoint.rewind(info.session_id, checkpoint_id)
    end
  end
end
