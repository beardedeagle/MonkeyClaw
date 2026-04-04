defmodule MonkeyClawWeb.VaultLive do
  @moduledoc """
  LiveView for vault secret management and model registry browsing.

  Provides a tabbed UI for managing encrypted API keys and OAuth
  tokens within a workspace, plus browsing cached AI models from
  the model registry.

  ## Routes

    * `/vault` — Default workspace vault management
    * `/vault/:workspace_id` — Specific workspace

  ## Features

    * **Secrets tab** — Create, list, and delete named API keys.
      Encrypted values are never displayed after creation.
    * **Tokens tab** — List and delete OAuth tokens with
      active/expired status indicators.
    * **Models tab** — Browse cached models grouped by provider,
      trigger refresh from provider APIs.

  ## Security Invariant

  Plaintext secret values are NEVER rendered in the UI. The value
  field exists only in the create form as a password input. After
  creation, only metadata (name, description, provider, last_used_at)
  is displayed.

  ## Design

  This is a LiveView. It is NOT a GenServer or long-lived process
  beyond the LiveView socket lifecycle. All state management
  delegates to the `Vault` and `ModelRegistry` context modules.
  """

  use MonkeyClawWeb, :live_view

  import Ecto.Query

  alias MonkeyClaw.ModelRegistry
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Vault
  alias MonkeyClaw.Vault.{Secret, Token}
  alias MonkeyClaw.Workspaces

  @impl true
  def mount(params, _session, socket) do
    workspace = resolve_workspace(params)

    socket =
      socket
      |> assign(:page_title, "Vault")
      |> assign(:workspace, workspace)
      |> assign(:workspace_id, workspace && workspace.id)
      |> assign(:default_workspace_id, workspace && workspace.id)
      |> assign(:active_tab, :secrets)
      |> assign(:secrets, list_secrets(workspace))
      |> assign(:tokens, list_tokens(workspace))
      |> assign(:models, list_models())
      |> assign(:show_form, false)
      |> assign(:form, nil)
      |> assign(:form_errors, [])
      |> assign(:refreshing_models, false)

    {:ok, socket, layout: {MonkeyClawWeb.Layouts, :app}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace = resolve_workspace(params)

    socket =
      socket
      |> assign(:workspace, workspace)
      |> assign(:workspace_id, workspace && workspace.id)
      |> assign(:default_workspace_id, workspace && workspace.id)
      |> assign(:secrets, list_secrets(workspace))
      |> assign(:tokens, list_tokens(workspace))
      |> assign(:models, list_models())

    {:noreply, socket}
  end

  # ── Tab Events ─────────────────────────────────────────────

  @impl true
  def handle_event("tab_secrets", _params, socket) do
    {:noreply, assign(socket, :active_tab, :secrets)}
  end

  def handle_event("tab_tokens", _params, socket) do
    {:noreply, assign(socket, :active_tab, :tokens)}
  end

  def handle_event("tab_models", _params, socket) do
    {:noreply, assign(socket, :active_tab, :models)}
  end

  # ── Secret Events ──────────────────────────────────────────

  def handle_event("new_secret", _params, socket) do
    form =
      to_form(%{"name" => "", "value" => "", "description" => "", "provider" => ""})

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form, form)
      |> assign(:form_errors, [])

    {:noreply, socket}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, form: nil, form_errors: [])}
  end

  def handle_event("save_secret", %{"secret" => params}, socket) do
    case socket.assigns.workspace do
      nil ->
        {:noreply, put_flash(socket, :error, "No workspace available")}

      workspace ->
        attrs = %{
          name: params["name"],
          value: params["value"],
          description: non_empty_or_nil(params["description"]),
          provider: non_empty_or_nil(params["provider"])
        }

        case Vault.create_secret(workspace, attrs) do
          {:ok, _secret} ->
            socket =
              socket
              |> assign(:secrets, list_secrets(workspace))
              |> assign(:show_form, false)
              |> assign(:form, nil)
              |> assign(:form_errors, [])
              |> put_flash(:info, "Secret created")

            {:noreply, socket}

          {:error, changeset} ->
            form = to_form(params)

            socket =
              socket
              |> assign(:form, form)
              |> assign(:form_errors, format_changeset_errors(changeset))

            {:noreply, socket}
        end
    end
  end

  def handle_event("delete_secret", %{"id" => id}, socket) do
    case socket.assigns.workspace do
      nil ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}

      workspace ->
        with {:ok, secret} <- Vault.get_secret(id),
             true <- secret.workspace_id == workspace.id,
             {:ok, _} <- Vault.delete_secret(secret) do
          {:noreply, assign(socket, :secrets, list_secrets(workspace))}
        else
          false ->
            {:noreply, put_flash(socket, :error, "Secret not found")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Secret not found")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end
    end
  end

  # ── Token Events ───────────────────────────────────────────

  def handle_event("delete_token", %{"id" => id}, socket) do
    case socket.assigns.workspace do
      nil ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}

      workspace ->
        with {:ok, token} <- fetch_token_by_id(id),
             true <- token.workspace_id == workspace.id,
             {:ok, _} <- Vault.delete_token(token) do
          {:noreply, assign(socket, :tokens, list_tokens(workspace))}
        else
          false ->
            {:noreply, put_flash(socket, :error, "Token not found")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Token not found")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end
    end
  end

  # ── Model Events ───────────────────────────────────────────

  def handle_event("refresh_models", _params, socket) do
    case spawn_refresh_task() do
      {:ok, _child} ->
        {:noreply, assign(socket, :refreshing_models, true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to refresh models: #{reason}")}
    end
  end

  # ── Async Refresh Results ───────────────────────────────────

  @impl true
  def handle_info({:refresh_models_result, :ok}, socket) do
    socket =
      socket
      |> assign(:models, list_models())
      |> assign(:refreshing_models, false)
      |> put_flash(:info, "Models refreshed")

    {:noreply, socket}
  end

  def handle_info({:refresh_models_result, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:refreshing_models, false)
      |> put_flash(:error, "Failed to refresh models: #{reason}")

    {:noreply, socket}
  end

  # Forward notification PubSub messages to the NotificationLive component.
  # The NotificationHook subscribes to the global topic. Messages arrive
  # in the parent LiveView process and are forwarded via send_update/3.
  def handle_info({:notification_created, _notification} = _msg, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Render ─────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Vault</h1>
          <p class="text-base-content/60 text-sm mt-1">
            Manage API keys, OAuth tokens, and browse available models
          </p>
        </div>
      </div>

      <%= if @workspace == nil do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-exclamation-triangle" class="size-12 text-warning" />
            <p class="text-base-content/60 mt-2">
              No workspace found. Create a workspace first to manage secrets and tokens.
            </p>
          </div>
        </div>
      <% else %>
        <div role="tablist" class="tabs tabs-bordered">
          <button
            role="tab"
            class={["tab", @active_tab == :secrets && "tab-active"]}
            phx-click="tab_secrets"
          >
            <.icon name="hero-key" class="size-4 mr-1" /> Secrets
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :tokens && "tab-active"]}
            phx-click="tab_tokens"
          >
            <.icon name="hero-lock-closed" class="size-4 mr-1" /> Tokens
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :models && "tab-active"]}
            phx-click="tab_models"
          >
            <.icon name="hero-cpu-chip" class="size-4 mr-1" /> Models
          </button>
        </div>

        {render_tab(assigns)}
      <% end %>
    </div>
    """
  end

  # ── Tab Renderers ──────────────────────────────────────────

  defp render_tab(%{active_tab: :secrets} = assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex justify-end">
        <button phx-click="new_secret" class="btn btn-primary btn-sm gap-2">
          <.icon name="hero-plus" class="size-4" /> Add Secret
        </button>
      </div>

      <%!-- Create Form --%>
      <div :if={@show_form} class="card bg-base-200 border border-primary/30">
        <div class="card-body p-4 space-y-4">
          <h3 class="font-semibold">New Secret</h3>

          <.form for={@form} phx-submit="save_secret" class="space-y-4" id="secret-form">
            <div class="form-control">
              <label class="label"><span class="label-text">Name</span></label>
              <input
                type="text"
                name="secret[name]"
                value={@form[:name].value}
                class="input input-bordered input-sm w-full"
                required
                placeholder="e.g. anthropic_key"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Value</span></label>
              <input
                type="password"
                name="secret[value]"
                value={@form[:value].value}
                class="input input-bordered input-sm w-full"
                required
                placeholder="sk-..."
                autocomplete="off"
              />
              <label class="label">
                <span class="label-text-alt text-base-content/40">
                  Encrypted at rest. Cannot be viewed after creation.
                </span>
              </label>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Description (optional)</span></label>
              <input
                type="text"
                name="secret[description]"
                value={@form[:description].value}
                class="input input-bordered input-sm w-full"
                placeholder="e.g. Anthropic API key for production"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Provider (optional)</span></label>
              <select name="secret[provider]" class="select select-bordered select-sm w-full">
                <option value="" selected={@form[:provider].value == ""}>None</option>
                <option
                  :for={provider <- Secret.valid_providers()}
                  value={provider}
                  selected={provider == @form[:provider].value}
                >
                  {provider_label(provider)}
                </option>
              </select>
            </div>

            <div :if={@form_errors != []} class="alert alert-error text-sm">
              <ul class="list-disc pl-4">
                <li :for={err <- @form_errors}>{err}</li>
              </ul>
            </div>

            <div class="flex gap-2 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">
                Create
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Secrets List --%>
      <div :if={@secrets == []} class="card bg-base-200 border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-key" class="size-12 text-base-content/30" />
          <p class="text-base-content/60 mt-2">
            No secrets stored. Add your first API key to get started.
          </p>
          <button :if={!@show_form} phx-click="new_secret" class="btn btn-primary btn-sm mt-4">
            Add your first secret
          </button>
        </div>
      </div>

      <div :if={@secrets != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>Description</th>
              <th>Provider</th>
              <th>Last Used</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={secret <- @secrets}>
              <td class="font-mono text-sm">{secret.name}</td>
              <td class="text-base-content/60 text-sm">{secret.description || "-"}</td>
              <td>
                <span :if={secret.provider} class="badge badge-primary badge-sm">
                  {provider_label(secret.provider)}
                </span>
                <span :if={!secret.provider} class="text-base-content/40">-</span>
              </td>
              <td class="text-sm text-base-content/60">
                {format_datetime(secret.last_used_at)}
              </td>
              <td class="text-right">
                <button
                  phx-click="delete_secret"
                  phx-value-id={secret.id}
                  data-confirm="Delete this secret? This cannot be undone."
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp render_tab(%{active_tab: :tokens} = assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Tokens List --%>
      <div :if={@tokens == []} class="card bg-base-200 border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-lock-closed" class="size-12 text-base-content/30" />
          <p class="text-base-content/60 mt-2">No OAuth tokens stored.</p>
        </div>
      </div>

      <div :if={@tokens != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Provider</th>
              <th>Type</th>
              <th>Scope</th>
              <th>Status</th>
              <th>Expires</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @tokens}>
              <td>
                <span class="badge badge-primary badge-sm">
                  {provider_label(token.provider)}
                </span>
              </td>
              <td class="text-sm">{token.token_type || "Bearer"}</td>
              <td class="text-sm text-base-content/60">{token.scope || "-"}</td>
              <td>
                <%= if token_expired?(token) do %>
                  <span class="badge badge-error badge-sm">Expired</span>
                <% else %>
                  <span class="badge badge-success badge-sm">Active</span>
                <% end %>
              </td>
              <td class="text-sm text-base-content/60">
                {format_datetime(token.expires_at)}
              </td>
              <td class="text-right">
                <button
                  phx-click="delete_token"
                  phx-value-id={token.id}
                  data-confirm="Delete this token? This cannot be undone."
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp render_tab(%{active_tab: :models} = assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex justify-end">
        <button
          phx-click="refresh_models"
          class="btn btn-primary btn-sm gap-2"
          disabled={@refreshing_models}
        >
          <.icon
            name="hero-arrow-path"
            class={["size-4", @refreshing_models && "animate-spin"]}
          />
          {if @refreshing_models, do: "Refreshing...", else: "Refresh Models"}
        </button>
      </div>

      <%!-- Models List --%>
      <div :if={@models == %{}} class="card bg-base-200 border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-cpu-chip" class="size-12 text-base-content/30" />
          <p class="text-base-content/60 mt-2">
            No cached models. Configure API keys in the Secrets tab, then refresh.
          </p>
        </div>
      </div>

      <div :for={{provider, models} <- @models} class="card bg-base-200 border border-base-300">
        <div class="card-body p-4">
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-2">
              <span class="badge badge-primary badge-sm">{provider_label(provider)}</span>
              <span class="text-xs text-base-content/40">
                {pluralize(length(models), "model")}
              </span>
            </div>
            <span class="text-xs text-base-content/40">
              Last refreshed: {format_refreshed_at(models)}
            </span>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Model ID</th>
                  <th>Display Name</th>
                  <th>Provider</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={model <- models}>
                  <td class="font-mono text-sm">{model.model_id}</td>
                  <td class="text-sm">{model.display_name}</td>
                  <td>
                    <span class="badge badge-primary badge-sm">
                      {provider_label(model.provider)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private — Workspace Resolution ─────────────────────────

  defp resolve_workspace(%{"workspace_id" => workspace_id}) do
    case Workspaces.get_workspace(workspace_id) do
      {:ok, workspace} -> workspace
      {:error, _} -> default_workspace()
    end
  end

  defp resolve_workspace(_params), do: default_workspace()

  defp default_workspace do
    case Workspaces.list_workspaces() do
      [workspace | _] -> workspace
      [] -> nil
    end
  end

  # ── Private — Data Loading ─────────────────────────────────

  defp list_secrets(nil), do: []

  defp list_secrets(workspace) do
    Vault.list_secrets(workspace.id)
  end

  defp list_tokens(nil), do: []

  defp list_tokens(workspace) do
    Vault.list_tokens(workspace.id)
  end

  defp list_models do
    if Process.whereis(ModelRegistry) do
      ModelRegistry.list_all_models()
    else
      %{}
    end
  end

  defp safe_refresh_models do
    if Process.whereis(ModelRegistry) do
      ModelRegistry.refresh_all()
    else
      {:error, "Model registry is not running"}
    end
  end

  # Spawn an async task for model refresh. Returns {:ok, pid} on
  # success or {:error, reason} if the registry or supervisor is
  # unavailable. Split into two functions to satisfy Credo's max
  # nesting depth of 2.
  @spec spawn_refresh_task() :: {:ok, pid()} | {:error, String.t()}
  defp spawn_refresh_task do
    case Process.whereis(ModelRegistry) do
      nil -> {:error, "Model registry is not running"}
      _pid -> start_refresh_child()
    end
  end

  defp start_refresh_child do
    lv = self()

    case Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
           result =
             try do
               safe_refresh_models()
             catch
               kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
             end

           send(lv, {:refresh_models_result, result})
         end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, "Failed to start model refresh task: #{inspect(reason)}"}
    end
  end

  # Vault context only exposes get_token(workspace_id, provider).
  # For deletion by ID we look up the token directly via Repo.
  # Uses a select to avoid decrypting EncryptedField values — we
  # only need id and workspace_id for authorization + deletion.
  defp fetch_token_by_id(id) when is_binary(id) do
    query =
      from t in Token,
        where: t.id == ^id,
        select: struct(t, [:id, :workspace_id, :provider, :inserted_at, :updated_at])

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  # ── Private — Formatting ───────────────────────────────────

  defp non_empty_or_nil(""), do: nil
  defp non_empty_or_nil(value) when is_binary(value), do: value
  defp non_empty_or_nil(_), do: nil

  defp provider_label("anthropic"), do: "Anthropic"
  defp provider_label("openai"), do: "OpenAI"
  defp provider_label("google"), do: "Google"
  defp provider_label("github_copilot"), do: "GitHub Copilot"
  defp provider_label("local"), do: "Local"
  defp provider_label(provider) when is_binary(provider), do: provider

  defp token_expired?(%Token{} = token), do: Token.expired?(token)

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_refreshed_at([]), do: "Never"

  defp format_refreshed_at(models) do
    models
    |> Enum.map(& &1.refreshed_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        "Never"

      timestamps ->
        timestamps |> Enum.max(fn a, b -> DateTime.compare(a, b) != :lt end) |> format_datetime()
    end
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp format_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> format_changeset_errors()
    |> Enum.join(", ")
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key -> interpolate_opt(opts, key) end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field}: #{&1}")
    end)
  end

  defp interpolate_opt(opts, key) do
    case Enum.find(opts, fn {k, _v} -> Atom.to_string(k) == key end) do
      {_k, v} -> to_string(v)
      nil -> key
    end
  end
end
