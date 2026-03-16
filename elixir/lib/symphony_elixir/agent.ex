defmodule SymphonyElixir.Agent do
  @moduledoc """
  Behaviour for agent backends that execute work in isolated workspaces.

  Symphony dispatches issues to agent backends via this interface.
  Each backend manages its own subprocess protocol (JSON-RPC for Codex,
  event streaming for Claude Code) behind a common session lifecycle.
  """

  @type session :: map()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @doc """
  Returns the agent module for the given agent kind.
  """
  @spec adapter(String.t()) :: module()
  def adapter("claude_code"), do: SymphonyElixir.ClaudeCode.AppServer
  def adapter(_), do: SymphonyElixir.Codex.AppServer
end
