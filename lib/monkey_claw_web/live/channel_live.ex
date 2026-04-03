defmodule MonkeyClawWeb.ChannelLive do
  @moduledoc """
  LiveView for managing channel adapter configurations.

  Provides a UI for creating, editing, enabling/disabling, and
  deleting channel configurations within a workspace. Each channel
  config connects an external platform adapter (Slack, Discord,
  Telegram, WhatsApp, Web) to the workspace's agent.

  ## Routes

    * `/channels` — Default workspace channel management
    * `/channels/:workspace_id` — Specific workspace

  ## Features

    * List all channel configs with status indicators
    * Create new channel configs with adapter-specific forms
    * Enable/disable channels without deleting config
    * Delete channel configs
    * View connection status for persistent adapters

  ## Design

  This is a LiveView. It is NOT a GenServer or long-lived process
  beyond the LiveView socket lifecycle. All state management
  delegates to the `Channels` context module.
  """

  use MonkeyClawWeb, :live_view

  alias MonkeyClaw.Channels
  alias MonkeyClaw.Channels.ChannelConfig
  alias MonkeyClaw.Workspaces

  @adapter_types ChannelConfig.adapter_types()

  @impl true
  def mount(params, _session, socket) do
    workspace = resolve_workspace(params)

    socket =
      socket
      |> assign(:page_title, "Channels")
      |> assign(:workspace, workspace)
      |> assign(:workspace_id, workspace && workspace.id)
      |> assign(:default_workspace_id, workspace && workspace.id)
      |> assign(:configs, list_configs(workspace))
      |> assign(:adapter_types, @adapter_types)
      |> assign(:show_form, false)
      |> assign(:editing_config, nil)
      |> assign(:form, nil)
      |> assign(:form_errors, [])

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
      |> assign(:configs, list_configs(workspace))

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_channel", _params, socket) do
    form =
      to_form(%{"adapter_type" => "slack", "name" => "", "enabled" => "true", "config" => %{}})

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:editing_config, nil)
      |> assign(:form, form)
      |> assign(:form_errors, [])

    {:noreply, socket}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing_config: nil, form: nil, form_errors: [])}
  end

  def handle_event("save_channel", %{"channel" => params}, socket) do
    workspace = socket.assigns.workspace
    editing_config = socket.assigns.editing_config

    # When editing, the adapter_type select is disabled (immutable),
    # so browsers won't submit it. Derive from the existing config.
    adapter_type =
      if editing_config do
        editing_config.adapter_type
      else
        parse_adapter_type(params["adapter_type"])
      end

    case adapter_type do
      nil ->
        {:noreply, put_flash(socket, :error, "Invalid adapter type")}

      adapter_type ->
        config = build_adapter_config(adapter_type, params)

        # When editing, preserve existing secret values for empty form fields.
        # Password inputs are blank in edit mode to avoid sending secrets to
        # the browser, so empty strings mean "keep existing value".
        config =
          if editing_config do
            merge_with_existing_config(config, editing_config.config)
          else
            config
          end

        attrs = %{
          name: params["name"],
          adapter_type: adapter_type,
          enabled: params["enabled"] == "true",
          config: config
        }

        case editing_config do
          nil ->
            handle_create(socket, workspace, attrs)

          config ->
            handle_update(socket, config, attrs)
        end
    end
  end

  def handle_event("edit_channel", %{"id" => id}, socket) do
    case Channels.get_config(id) do
      {:ok, config} ->
        form =
          to_form(%{
            "adapter_type" => to_string(config.adapter_type),
            "name" => config.name,
            "enabled" => to_string(config.enabled),
            "config" => config.config
          })

        socket =
          socket
          |> assign(:show_form, true)
          |> assign(:editing_config, config)
          |> assign(:form, form)
          |> assign(:form_errors, [])

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Channel config not found")}
    end
  end

  def handle_event("toggle_channel", %{"id" => id}, socket) do
    case Channels.get_config(id) do
      {:ok, config} ->
        case Channels.update_config(config, %{enabled: !config.enabled}) do
          {:ok, _updated} ->
            {:noreply, assign(socket, :configs, list_configs(socket.assigns.workspace))}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Channel config not found")}
    end
  end

  def handle_event("delete_channel", %{"id" => id}, socket) do
    with {:ok, config} <- Channels.get_config(id),
         {:ok, _} <- Channels.delete_config(config) do
      {:noreply, assign(socket, :configs, list_configs(socket.assigns.workspace))}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Channel config not found")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  # Forward notification PubSub messages to the NotificationLive component.
  # The NotificationHook subscribes to the global topic. Messages arrive
  # in the parent LiveView process and are forwarded via send_update/3.
  @impl true
  def handle_info({:notification_created, _notification} = _msg, socket) do
    # NotificationHook handles forwarding — halt in hook means we don't reach here
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Channel Adapters</h1>
          <p class="text-base-content/60 text-sm mt-1">
            Connect external platforms to your workspace agent
          </p>
        </div>
        <button phx-click="new_channel" class="btn btn-primary btn-sm gap-2">
          <.icon name="hero-plus" class="size-4" /> New Channel
        </button>
      </div>

      <%!-- Channel Config List --%>
      <div :if={@configs == []} class="card bg-base-200 border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-signal" class="size-12 text-base-content/30" />
          <p class="text-base-content/60 mt-2">No channel adapters configured</p>
          <button phx-click="new_channel" class="btn btn-primary btn-sm mt-4">
            Add your first channel
          </button>
        </div>
      </div>

      <div :for={config <- @configs} class="card bg-base-200 border border-base-300">
        <div class="card-body p-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class={["w-2 h-2 rounded-full", status_dot_color(config.status)]} />
              <div>
                <h3 class="font-semibold">{config.name}</h3>
                <span class="text-xs text-base-content/60">
                  {config.adapter_type} · {config.status}
                </span>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <label class="swap">
                <input
                  type="checkbox"
                  checked={config.enabled}
                  phx-click="toggle_channel"
                  phx-value-id={config.id}
                />
                <span class="swap-on badge badge-success badge-sm">Enabled</span>
                <span class="swap-off badge badge-ghost badge-sm">Disabled</span>
              </label>
              <button
                phx-click="edit_channel"
                phx-value-id={config.id}
                class="btn btn-ghost btn-xs"
              >
                Edit
              </button>
              <button
                phx-click="delete_channel"
                phx-value-id={config.id}
                data-confirm="Delete this channel config? This cannot be undone."
                class="btn btn-ghost btn-xs text-error"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Create/Edit Form Modal --%>
      <div :if={@show_form} class="card bg-base-200 border border-primary/30">
        <div class="card-body p-4 space-y-4">
          <h3 class="font-semibold">
            {if @editing_config, do: "Edit Channel", else: "New Channel"}
          </h3>

          <.form for={@form} phx-submit="save_channel" class="space-y-4" id="channel-form">
            <div class="form-control">
              <label class="label"><span class="label-text">Name</span></label>
              <input
                type="text"
                name="channel[name]"
                value={@form[:name].value}
                class="input input-bordered input-sm w-full"
                required
                placeholder="e.g. Production Slack"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Adapter Type</span></label>
              <select
                name="channel[adapter_type]"
                class="select select-bordered select-sm w-full"
                disabled={@editing_config != nil}
              >
                <option
                  :for={type <- @adapter_types}
                  value={type}
                  selected={to_string(type) == @form[:adapter_type].value}
                >
                  {type |> to_string() |> String.capitalize()}
                </option>
              </select>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Enabled</span>
              </label>
              <input
                type="checkbox"
                name="channel[enabled]"
                value="true"
                checked={@form[:enabled].value == "true"}
                class="toggle toggle-primary"
              />
            </div>

            <%!-- Adapter-specific config fields --%>
            <div class="divider text-xs text-base-content/40">Adapter Configuration</div>

            {render_adapter_fields(assigns)}

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
                {if @editing_config, do: "Update", else: "Create"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # ── Adapter-Specific Form Fields ─────────────────────────────

  defp render_adapter_fields(assigns) do
    adapter_type = assigns.form[:adapter_type].value

    case adapter_type do
      "slack" -> render_slack_fields(assigns)
      "discord" -> render_discord_fields(assigns)
      "telegram" -> render_telegram_fields(assigns)
      "whatsapp" -> render_whatsapp_fields(assigns)
      "web" -> render_web_fields(assigns)
      _ -> render_web_fields(assigns)
    end
  end

  defp render_slack_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="form-control">
        <label class="label"><span class="label-text">Bot Token</span></label>
        <input
          type="password"
          name="channel[bot_token]"
          value={if @editing_config, do: "", else: get_in(@form[:config].value, ["bot_token"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder={if @editing_config, do: "Stored (leave blank to keep)", else: "xoxb-..."}
          autocomplete="off"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Signing Secret</span></label>
        <input
          type="password"
          name="channel[signing_secret]"
          value={
            if @editing_config, do: "", else: get_in(@form[:config].value, ["signing_secret"]) || ""
          }
          class="input input-bordered input-sm w-full"
          placeholder={if @editing_config, do: "Stored (leave blank to keep)", else: ""}
          autocomplete="off"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Channel ID</span></label>
        <input
          type="text"
          name="channel[channel_id]"
          value={get_in(@form[:config].value, ["channel_id"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder="C0123456789"
        />
      </div>
    </div>
    """
  end

  defp render_discord_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="form-control">
        <label class="label"><span class="label-text">Bot Token</span></label>
        <input
          type="password"
          name="channel[bot_token]"
          value={if @editing_config, do: "", else: get_in(@form[:config].value, ["bot_token"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder={if @editing_config, do: "Stored (leave blank to keep)", else: ""}
          autocomplete="off"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Application ID</span></label>
        <input
          type="text"
          name="channel[application_id]"
          value={get_in(@form[:config].value, ["application_id"]) || ""}
          class="input input-bordered input-sm w-full"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Public Key (hex)</span></label>
        <input
          type="text"
          name="channel[public_key]"
          value={get_in(@form[:config].value, ["public_key"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder="Ed25519 public key in hex"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Channel ID</span></label>
        <input
          type="text"
          name="channel[channel_id]"
          value={get_in(@form[:config].value, ["channel_id"]) || ""}
          class="input input-bordered input-sm w-full"
        />
      </div>
    </div>
    """
  end

  defp render_telegram_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="form-control">
        <label class="label"><span class="label-text">Bot Token</span></label>
        <input
          type="password"
          name="channel[bot_token]"
          value={if @editing_config, do: "", else: get_in(@form[:config].value, ["bot_token"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder={if @editing_config, do: "Stored (leave blank to keep)", else: ""}
          autocomplete="off"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Chat ID</span></label>
        <input
          type="text"
          name="channel[chat_id]"
          value={get_in(@form[:config].value, ["chat_id"]) || ""}
          class="input input-bordered input-sm w-full"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Secret Token</span></label>
        <input
          type="password"
          name="channel[secret_token]"
          value={
            if @editing_config, do: "", else: get_in(@form[:config].value, ["secret_token"]) || ""
          }
          class="input input-bordered input-sm w-full"
          autocomplete="off"
          placeholder={
            if @editing_config,
              do: "Stored (leave blank to keep)",
              else: "X-Telegram-Bot-Api-Secret-Token value"
          }
        />
      </div>
    </div>
    """
  end

  defp render_whatsapp_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="form-control">
        <label class="label"><span class="label-text">Access Token</span></label>
        <input
          type="password"
          name="channel[access_token]"
          value={
            if @editing_config, do: "", else: get_in(@form[:config].value, ["access_token"]) || ""
          }
          class="input input-bordered input-sm w-full"
          autocomplete="off"
          placeholder={
            if @editing_config,
              do: "Stored (leave blank to keep)",
              else: "WhatsApp Business API token"
          }
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Phone Number ID</span></label>
        <input
          type="text"
          name="channel[phone_number_id]"
          value={get_in(@form[:config].value, ["phone_number_id"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder="From Meta Business Suite"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Recipient Phone</span></label>
        <input
          type="text"
          name="channel[recipient_phone]"
          value={get_in(@form[:config].value, ["recipient_phone"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder="E.164 format: +1234567890"
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">App Secret</span></label>
        <input
          type="password"
          name="channel[app_secret]"
          value={if @editing_config, do: "", else: get_in(@form[:config].value, ["app_secret"]) || ""}
          class="input input-bordered input-sm w-full"
          autocomplete="off"
          placeholder={
            if @editing_config,
              do: "Stored (leave blank to keep)",
              else: "Meta app secret for signature verification"
          }
        />
      </div>
      <div class="form-control">
        <label class="label"><span class="label-text">Verify Token</span></label>
        <input
          type="text"
          name="channel[verify_token]"
          value={get_in(@form[:config].value, ["verify_token"]) || ""}
          class="input input-bordered input-sm w-full"
          placeholder="Token for webhook verification challenge"
        />
      </div>
    </div>
    """
  end

  defp render_web_fields(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      The Web adapter uses PubSub for real-time delivery through the LiveView
      chat interface. No external configuration is required.
    </p>
    """
  end

  # ── Private ──────────────────────────────────────────────────

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

  defp list_configs(nil), do: []

  defp list_configs(workspace) do
    Channels.list_configs(workspace.id)
  end

  defp handle_create(socket, %MonkeyClaw.Workspaces.Workspace{} = workspace, attrs) do
    case Channels.create_config(workspace, attrs) do
      {:ok, _config} ->
        socket =
          socket
          |> assign(:configs, list_configs(workspace))
          |> assign(:show_form, false)
          |> assign(:form, nil)
          |> assign(:form_errors, [])
          |> put_flash(:info, "Channel created")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form_errors, format_changeset_errors(changeset))}
    end
  end

  defp handle_update(socket, config, attrs) do
    case Channels.update_config(config, attrs) do
      {:ok, _config} ->
        socket =
          socket
          |> assign(:configs, list_configs(socket.assigns.workspace))
          |> assign(:show_form, false)
          |> assign(:editing_config, nil)
          |> assign(:form, nil)
          |> assign(:form_errors, [])
          |> put_flash(:info, "Channel updated")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form_errors, format_changeset_errors(changeset))}
    end
  end

  # Safe adapter type parsing — matches against the known allow-list
  # instead of String.to_existing_atom on client-provided input.
  defp parse_adapter_type(type_string) when is_binary(type_string) do
    Enum.find(@adapter_types, fn type -> Atom.to_string(type) == type_string end)
  end

  defp parse_adapter_type(_), do: nil

  defp build_adapter_config(:slack, params) do
    extract_params(params, ~w(bot_token signing_secret channel_id))
  end

  defp build_adapter_config(:discord, params) do
    extract_params(params, ~w(bot_token application_id public_key channel_id))
  end

  defp build_adapter_config(:telegram, params) do
    extract_params(params, ~w(bot_token chat_id secret_token))
  end

  defp build_adapter_config(:whatsapp, params) do
    extract_params(
      params,
      ~w(access_token phone_number_id recipient_phone app_secret verify_token)
    )
  end

  defp build_adapter_config(:web, _params), do: %{}

  defp extract_params(params, keys) do
    Map.new(keys, fn key -> {key, params[key] || ""} end)
  end

  # Merges a newly-built adapter config with the existing stored config,
  # preserving existing values for any fields that are blank in the form.
  # Password inputs are intentionally blanked in edit mode to avoid
  # sending secrets to the browser; an empty string means "keep existing".
  defp merge_with_existing_config(new_config, existing_config)
       when is_map(new_config) and is_map(existing_config) do
    Map.merge(existing_config, new_config, fn _key, existing_val, new_val ->
      if new_val == "" or is_nil(new_val), do: existing_val, else: new_val
    end)
  end

  defp status_dot_color(:connected), do: "bg-success"
  defp status_dot_color(:error), do: "bg-error"
  defp status_dot_color(:disconnected), do: "bg-base-content/30"
  defp status_dot_color(_), do: "bg-base-content/30"

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
