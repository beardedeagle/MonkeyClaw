defmodule MonkeyClaw.Workflows do
  @moduledoc """
  Context module for MonkeyClaw workflow operations.

  Provides the public API for executing product-level workflows
  that compose domain entities, agent sessions, and extensions
  into user-facing operations.

  ## Available Workflows

    * **Conversation** — Send a message to an AI agent through a
      workspace channel. The canonical "talk to an agent" flow.

  ## What Is a Workflow

  A workflow is a product-level recipe that orchestrates existing
  APIs into a cohesive user-facing operation. Workflows live in
  MonkeyClaw — generic mechanics stay in BeamAgent.

  Each workflow composes:

    * Domain entity resolution (Workspaces, Assistants)
    * Session and thread lifecycle (AgentBridge)
    * Extension hook execution (Extensions)
    * Error handling and validation

  Workflow recipes are the glue between MonkeyClaw's product
  layer and BeamAgent's runtime substrate. They are where
  product decisions (what happens when a user sends a message)
  become concrete code.

  ## Design

  This module is NOT a process. Workflows are stateless
  orchestration functions. The caller's process (e.g., a LiveView
  or controller) provides execution context.

  ## Related Modules

    * `MonkeyClaw.Workflows.Conversation` — Conversation workflow
    * `MonkeyClaw.AgentBridge` — Session and query management
    * `MonkeyClaw.Extensions` — Hook execution
    * `MonkeyClaw.Workspaces` — Domain entity resolution
  """

  alias MonkeyClaw.Workflows.Conversation

  @doc """
  Send a message to an AI agent through a workspace channel.

  Orchestrates the full "talk to an agent" flow: loads the
  workspace and assistant, ensures a session and thread are
  running, fires extension hooks, sends the query, and returns
  the response.

  Delegates to `MonkeyClaw.Workflows.Conversation.send_message/4`.
  See that module for full documentation.

  ## Examples

      MonkeyClaw.Workflows.send_message(workspace_id, "general", "Hello!")
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) ::
          Conversation.message_result()
  defdelegate send_message(workspace_id, channel_name, prompt, opts \\ []),
    to: Conversation
end
