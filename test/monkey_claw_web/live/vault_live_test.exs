defmodule MonkeyClawWeb.VaultLiveTest do
  @moduledoc """
  Integration tests for `MonkeyClawWeb.VaultLive`.

  Tests the full LiveView lifecycle: mount, tab navigation, secret
  CRUD, token display, model registry browsing, and the security
  invariant that plaintext secret values never appear in rendered HTML.

  All tests use real database operations through Ecto sandbox — no mocks.
  ModelRegistry is disabled in test config (`:start_model_registry` = false),
  so the LiveView exercises its graceful-degradation code paths.
  """

  use MonkeyClawWeb.ConnCase, async: true

  import MonkeyClaw.Factory
  import Phoenix.LiveViewTest

  alias MonkeyClaw.Vault

  # ── Mount ─────────────────────────────────────────────────────

  describe "mount/3" do
    test "renders empty state when no workspace exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/vault")

      assert html =~ "No workspace found"
      assert html =~ "Create a workspace first"
      # Tab bar should NOT render without a workspace
      refute html =~ "tab_secrets"
    end

    test "renders secrets tab by default with workspace", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, _view, html} = live(conn, "/vault")

      assert html =~ "Vault"
      assert html =~ "tab-active"
      assert html =~ "Secrets"
      assert html =~ "No secrets stored"
    end

    test "resolves workspace from URL param", %{conn: conn} do
      workspace = insert_workspace!()

      {:ok, _view, html} = live(conn, "/vault/#{workspace.id}")

      assert html =~ "Vault"
      assert html =~ "No secrets stored"
    end

    test "falls back to default workspace on invalid workspace_id", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, _view, html} = live(conn, "/vault/#{Ecto.UUID.generate()}")

      # Falls back to default workspace (first one), still renders
      assert html =~ "Vault"
    end
  end

  # ── Tab Navigation ────────────────────────────────────────────

  describe "tab navigation" do
    setup %{conn: conn} do
      workspace = insert_workspace!()
      {:ok, view, _html} = live(conn, "/vault")
      %{view: view, workspace: workspace}
    end

    test "switches to tokens tab", %{view: view} do
      html = render_click(view, "tab_tokens")

      assert html =~ "No OAuth tokens stored"
    end

    test "switches to models tab", %{view: view} do
      html = render_click(view, "tab_models")

      assert html =~ "No cached models"
      assert html =~ "Refresh Models"
    end

    test "switches back to secrets tab", %{view: view} do
      render_click(view, "tab_tokens")
      html = render_click(view, "tab_secrets")

      assert html =~ "Add Secret"
      assert html =~ "No secrets stored"
    end
  end

  # ── Secret CRUD ───────────────────────────────────────────────

  describe "secret creation" do
    setup %{conn: conn} do
      workspace = insert_workspace!()
      {:ok, view, _html} = live(conn, "/vault")
      %{view: view, workspace: workspace}
    end

    test "opens new secret form", %{view: view} do
      html = render_click(view, "new_secret")

      assert html =~ "New Secret"
      assert html =~ "secret-form"
      assert html =~ ~s(type="password")
      assert html =~ "Cannot be viewed after creation"
    end

    test "cancels form and hides it", %{view: view} do
      render_click(view, "new_secret")
      html = render_click(view, "cancel_form")

      refute html =~ "New Secret"
      refute html =~ "secret-form"
    end

    test "creates a secret successfully", %{view: view, workspace: workspace} do
      render_click(view, "new_secret")

      html =
        render_submit(view, "save_secret", %{
          "secret" => %{
            "name" => "my_api_key",
            "value" => "sk-test-secret-value-12345",
            "description" => "Test API key",
            "provider" => "anthropic"
          }
        })

      # Form closes, secret appears in list
      refute html =~ "New Secret"
      assert html =~ "my_api_key"
      assert html =~ "Test API key"
      assert html =~ "Anthropic"

      # Verify the secret was persisted
      assert [secret] = Vault.list_secrets(workspace.id)
      assert secret.name == "my_api_key"
      assert secret.description == "Test API key"
      assert secret.provider == "anthropic"
    end

    test "creates a secret without optional fields", %{view: view, workspace: workspace} do
      render_click(view, "new_secret")

      html =
        render_submit(view, "save_secret", %{
          "secret" => %{
            "name" => "bare_key",
            "value" => "some-value",
            "description" => "",
            "provider" => ""
          }
        })

      assert html =~ "bare_key"
      assert [secret] = Vault.list_secrets(workspace.id)
      assert secret.name == "bare_key"
      assert secret.description == nil
      assert secret.provider == nil
    end

    test "shows validation errors on duplicate name", %{view: view, workspace: workspace} do
      insert_vault_secret!(workspace, %{name: "existing_key"})

      render_click(view, "new_secret")

      # Re-render to pick up the newly created secret, then open form
      {:ok, view, _html} = live(build_conn(), "/vault")
      render_click(view, "new_secret")

      html =
        render_submit(view, "save_secret", %{
          "secret" => %{
            "name" => "existing_key",
            "value" => "another-value",
            "description" => "",
            "provider" => ""
          }
        })

      # Form should stay open with error
      assert html =~ "secret-form"
      assert html =~ "already been taken" or html =~ "has already been taken"
    end

    test "shows validation errors on invalid name format", %{view: view} do
      render_click(view, "new_secret")

      html =
        render_submit(view, "save_secret", %{
          "secret" => %{
            "name" => "invalid name with spaces!",
            "value" => "some-value",
            "description" => "",
            "provider" => ""
          }
        })

      assert html =~ "secret-form"
      assert html =~ "must contain only"
    end
  end

  describe "secret deletion" do
    setup %{conn: conn} do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace, %{name: "delete_me"})
      {:ok, view, _html} = live(conn, "/vault")
      %{view: view, workspace: workspace, secret: secret}
    end

    test "deletes a secret", %{view: view, workspace: workspace, secret: secret} do
      html = render_click(view, "delete_secret", %{"id" => secret.id})

      refute html =~ "delete_me"
      assert Vault.list_secrets(workspace.id) == []
    end

    test "shows error flash on delete of missing secret", %{view: view} do
      missing_id = Ecto.UUID.generate()

      html = render_click(view, "delete_secret", %{"id" => missing_id})

      assert html =~ "Secret not found"
    end
  end

  describe "secrets listing" do
    setup %{conn: conn} do
      workspace = insert_workspace!()

      insert_vault_secret!(workspace, %{
        name: "alpha_key",
        description: "First key",
        provider: "anthropic"
      })

      insert_vault_secret!(workspace, %{
        name: "beta_key",
        description: "Second key",
        provider: "openai"
      })

      {:ok, view, html} = live(conn, "/vault")
      %{view: view, workspace: workspace, html: html}
    end

    test "lists all secrets for workspace", %{html: html} do
      assert html =~ "alpha_key"
      assert html =~ "First key"
      assert html =~ "Anthropic"
      assert html =~ "beta_key"
      assert html =~ "Second key"
      assert html =~ "OpenAI"
    end

    test "does not show empty state when secrets exist", %{html: html} do
      refute html =~ "No secrets stored"
    end
  end

  # ── Token Display ─────────────────────────────────────────────

  describe "token listing" do
    setup %{conn: conn} do
      workspace = insert_workspace!()

      # Active token (expires in the future)
      insert_vault_token!(workspace, %{
        provider: "anthropic",
        access_token: "at-active-token",
        token_type: "Bearer",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      # Expired token
      insert_vault_token!(workspace, %{
        provider: "openai",
        access_token: "at-expired-token",
        token_type: "Bearer",
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      {:ok, view, _html} = live(conn, "/vault")
      html = render_click(view, "tab_tokens")
      %{view: view, workspace: workspace, html: html}
    end

    test "shows active token with Active badge", %{html: html} do
      assert html =~ "Anthropic"
      assert html =~ "Active"
    end

    test "shows expired token with Expired badge", %{html: html} do
      assert html =~ "OpenAI"
      assert html =~ "Expired"
    end

    test "displays token type", %{html: html} do
      assert html =~ "Bearer"
    end
  end

  describe "token deletion" do
    setup %{conn: conn} do
      workspace = insert_workspace!()

      token =
        insert_vault_token!(workspace, %{
          provider: "anthropic",
          access_token: "at-delete-me"
        })

      {:ok, view, _html} = live(conn, "/vault")
      render_click(view, "tab_tokens")
      %{view: view, workspace: workspace, token: token}
    end

    test "deletes a token", %{view: view, workspace: workspace, token: token} do
      html = render_click(view, "delete_token", %{"id" => token.id})

      refute html =~ "Anthropic"
      assert Vault.list_tokens(workspace.id) == []
    end

    test "shows error flash on delete of missing token", %{view: view} do
      missing_id = Ecto.UUID.generate()

      html = render_click(view, "delete_token", %{"id" => missing_id})

      assert html =~ "Token not found"
    end
  end

  describe "token empty state" do
    test "shows empty state when no tokens exist", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, view, _html} = live(conn, "/vault")
      html = render_click(view, "tab_tokens")

      assert html =~ "No OAuth tokens stored"
    end
  end

  # ── Models Tab ────────────────────────────────────────────────

  describe "models tab" do
    setup %{conn: conn} do
      _workspace = insert_workspace!()
      {:ok, view, _html} = live(conn, "/vault")
      %{view: view}
    end

    test "shows empty state when no models cached", %{view: view} do
      html = render_click(view, "tab_models")

      assert html =~ "No cached models"
      assert html =~ "Configure API keys"
    end

    test "shows refresh button", %{view: view} do
      html = render_click(view, "tab_models")

      assert html =~ "Refresh Models"
    end

    test "handles refresh when ModelRegistry is not running", %{view: view} do
      render_click(view, "tab_models")

      html = render_click(view, "refresh_models")

      assert html =~ "Failed to refresh models"
      assert html =~ "Model registry is not running"
    end
  end

  # NOTE: ModelRegistry GenServer integration with VaultLive is not tested
  # here because the GenServer requires DB access during init/1, which
  # conflicts with async sandbox mode. The ModelRegistry's own test suite
  # (model_registry_test.exs, async: false) thoroughly covers GenServer
  # lifecycle, refresh, and ETS cache. The VaultLive graceful-degradation
  # path (ModelRegistry not running) is tested above in "models tab".

  # ── Security Invariant ────────────────────────────────────────

  describe "security invariant" do
    test "never renders plaintext secret value in HTML", %{conn: conn} do
      workspace = insert_workspace!()
      plaintext = "sk-super-secret-api-key-that-must-never-appear"

      insert_vault_secret!(workspace, %{
        name: "sensitive_key",
        value: plaintext
      })

      {:ok, _view, html} = live(conn, "/vault")

      # The plaintext value must NEVER appear in rendered HTML
      refute html =~ plaintext
      # The name is metadata and is shown
      assert html =~ "sensitive_key"
    end

    test "secret form uses password input type", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, view, _html} = live(conn, "/vault")
      html = render_click(view, "new_secret")

      # The value field must be a password field
      assert html =~ ~s(type="password")
      assert html =~ ~s(autocomplete="off")
    end

    test "never renders encrypted_value bytes in HTML", %{conn: conn} do
      workspace = insert_workspace!()

      secret =
        insert_vault_secret!(workspace, %{
          name: "cipher_test",
          value: "plaintext-to-encrypt"
        })

      {:ok, _view, html} = live(conn, "/vault")

      # encrypted_value is raw binary — ensure no form of it leaks
      refute html =~ "plaintext-to-encrypt"
      # The encrypted binary would contain non-printable chars,
      # but also check that Base64 of the ciphertext isn't rendered
      refute html =~ Base.encode64(secret.encrypted_value)
    end

    test "token access_token values are not rendered", %{conn: conn} do
      workspace = insert_workspace!()

      insert_vault_token!(workspace, %{
        provider: "anthropic",
        access_token: "at-secret-token-value-xyz"
      })

      {:ok, view, _html} = live(conn, "/vault")
      html = render_click(view, "tab_tokens")

      # Token access_token must never appear in rendered HTML
      refute html =~ "at-secret-token-value-xyz"
      # But provider name is shown
      assert html =~ "Anthropic"
    end
  end

  # ── Workspace Isolation ───────────────────────────────────────

  describe "workspace isolation" do
    test "only shows secrets for the resolved workspace", %{conn: conn} do
      workspace_a = insert_workspace!()
      workspace_b = insert_workspace!()

      insert_vault_secret!(workspace_a, %{name: "key_in_a"})
      insert_vault_secret!(workspace_b, %{name: "key_in_b"})

      {:ok, _view, html} = live(conn, "/vault/#{workspace_a.id}")

      assert html =~ "key_in_a"
      refute html =~ "key_in_b"
    end

    test "only shows tokens for the resolved workspace", %{conn: conn} do
      workspace_a = insert_workspace!()
      workspace_b = insert_workspace!()

      insert_vault_token!(workspace_a, %{
        provider: "anthropic",
        access_token: "at-ws-a-token"
      })

      insert_vault_token!(workspace_b, %{
        provider: "openai",
        access_token: "at-ws-b-token"
      })

      {:ok, view, _html} = live(conn, "/vault/#{workspace_a.id}")
      html = render_click(view, "tab_tokens")

      assert html =~ "Anthropic"
      refute html =~ "OpenAI"
    end
  end

  # ── Provider Label Formatting ─────────────────────────────────

  describe "provider label formatting" do
    test "renders known provider labels correctly", %{conn: conn} do
      workspace = insert_workspace!()

      insert_vault_secret!(workspace, %{name: "k1", provider: "anthropic"})
      insert_vault_secret!(workspace, %{name: "k2", provider: "openai"})
      insert_vault_secret!(workspace, %{name: "k3", provider: "google"})
      insert_vault_secret!(workspace, %{name: "k4", provider: "github_copilot"})
      insert_vault_secret!(workspace, %{name: "k5", provider: "local"})

      {:ok, _view, html} = live(conn, "/vault")

      assert html =~ "Anthropic"
      assert html =~ "OpenAI"
      assert html =~ "Google"
      assert html =~ "GitHub Copilot"
      assert html =~ "Local"
    end
  end

  # ── Handle Info ───────────────────────────────────────────────

  describe "handle_info/2" do
    test "ignores notification_created messages without crashing", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, view, _html} = live(conn, "/vault")

      # Simulate a PubSub notification message arriving
      send(view.pid, {:notification_created, %{id: "fake"}})

      # LiveView should still be alive and rendering
      html = render(view)
      assert html =~ "Vault"
    end

    test "ignores unknown messages without crashing", %{conn: conn} do
      _workspace = insert_workspace!()

      {:ok, view, _html} = live(conn, "/vault")

      send(view.pid, {:unexpected_message, "test"})

      html = render(view)
      assert html =~ "Vault"
    end
  end
end
