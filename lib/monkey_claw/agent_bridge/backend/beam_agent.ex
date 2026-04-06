defmodule MonkeyClaw.AgentBridge.Backend.BeamAgent do
  @moduledoc """
  Production backend adapter wrapping the BeamAgent runtime.

  Each callback delegates to the corresponding `BeamAgent` or
  `BeamAgent.Threads` function. This module exists solely to
  satisfy the `MonkeyClaw.AgentBridge.Backend` behaviour contract,
  keeping the Session GenServer decoupled from the concrete
  BeamAgent API.

  This is the default backend used when no `:backend` key is
  present in the session config.
  """

  @behaviour MonkeyClaw.AgentBridge.Backend

  alias MonkeyClaw.ModelRegistry.Provider

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

  @impl true
  def list_models(opts) when is_map(opts) do
    backend = Map.get(opts, :backend)
    provider = backend_to_provider(backend)

    provider_opts =
      opts
      |> Map.to_list()
      |> Keyword.take([:workspace_id, :secret_name, :api_key, :base_url])

    case Provider.fetch_models(provider, provider_opts) do
      {:ok, models} ->
        {:ok, Enum.map(models, &annotate_provider(&1, provider))}

      {:error, _} = error ->
        error
    end
  end

  # Map the MonkeyClaw backend identifier to the upstream provider name.
  # Static table — future SDK and local backends extend this.
  defp backend_to_provider("claude"), do: "anthropic"
  defp backend_to_provider("codex"), do: "openai"
  defp backend_to_provider("gemini"), do: "google"
  defp backend_to_provider("opencode"), do: "anthropic"
  defp backend_to_provider("copilot"), do: "github_copilot"
  defp backend_to_provider(nil), do: "anthropic"
  defp backend_to_provider(other) when is_binary(other), do: other

  defp annotate_provider(%{model_id: id, display_name: name, capabilities: caps}, provider) do
    %{
      provider: provider,
      model_id: id,
      display_name: name,
      capabilities: caps
    }
  end

  # ── Checkpoint Operations ────────────────────────────────────

  # BeamAgent.Checkpoint does not yet export save/2 or rewind/2.
  # These raise until the upstream API ships. The experiment Runner
  # rescues at the trust boundary and degrades gracefully (nil
  # checkpoint_id skips rewind). No silent stubs.
  # Dialyzer: intentional no_return — these always raise.
  @dialyzer {:nowarn_function, [checkpoint_save: 2, checkpoint_rewind: 2]}

  @impl true
  def checkpoint_save(_pid, _label) do
    raise "BeamAgent.Checkpoint.save/2 is not yet available in beam_agent"
  end

  @impl true
  def checkpoint_rewind(_pid, _checkpoint_id) do
    raise "BeamAgent.Checkpoint.rewind/2 is not yet available in beam_agent"
  end
end
