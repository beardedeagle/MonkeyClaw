defmodule MonkeyClaw do
  @moduledoc """
  MonkeyClaw — secure-by-default personal AI assistant on BeamAgent.

  This is the domain layer providing contexts for:

    * Agent session management via `MonkeyClaw.AgentBridge`
    * Assistant identity and personas via `MonkeyClaw.Assistants`
    * Workspace and channel organization via `MonkeyClaw.Workspaces`
    * Workflow orchestration (planned)

  ## Security Model

  MonkeyClaw inherits BEAM's process isolation and adds:

    * Default-deny policy for all system access
    * Audit trail for every agent action via BeamAgent.Journal
    * No implicit filesystem or network access
    * Encrypted distribution for multi-node deployments
  """
end
