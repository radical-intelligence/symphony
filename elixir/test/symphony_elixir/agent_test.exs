defmodule SymphonyElixir.AgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent

  describe "adapter/1" do
    test "returns Codex AppServer for 'codex'" do
      assert Agent.adapter("codex") == SymphonyElixir.Codex.AppServer
    end

    test "returns Claude Code AppServer for 'claude_code'" do
      assert Agent.adapter("claude_code") == SymphonyElixir.ClaudeCode.AppServer
    end

    test "defaults to Codex AppServer for unknown kinds" do
      assert Agent.adapter("unknown") == SymphonyElixir.Codex.AppServer
    end

    test "defaults to Codex AppServer for nil" do
      assert Agent.adapter(nil) == SymphonyElixir.Codex.AppServer
    end
  end

  describe "config schema agent_kind" do
    test "parses agent_kind from workflow" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude_code")

      settings = Config.settings!()
      assert settings.agent.agent_kind == "claude_code"
    end

    test "defaults agent_kind to codex" do
      write_workflow_file!(Workflow.workflow_file_path())

      settings = Config.settings!()
      assert settings.agent.agent_kind == "codex"
    end

    test "parses agent_kind 'any'" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "any")

      settings = Config.settings!()
      assert settings.agent.agent_kind == "any"
    end

    test "rejects invalid agent_kind" do
      result =
        SymphonyElixir.Config.Schema.parse(%{
          "tracker" => %{"kind" => "memory"},
          "agent" => %{"agent_kind" => "invalid_agent"}
        })

      assert {:error, {:invalid_workflow_config, msg}} = result
      assert msg =~ "agent_kind"
    end

    test "parses agent_kind_by_state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "any",
        agent_kind_by_state: %{"In Progress" => "claude_code", "Rework" => "codex"}
      )

      settings = Config.settings!()
      assert settings.agent.agent_kind_by_state == %{"in progress" => "claude_code", "rework" => "codex"}
    end

    test "rejects invalid agent kind in agent_kind_by_state" do
      result =
        SymphonyElixir.Config.Schema.parse(%{
          "tracker" => %{"kind" => "memory"},
          "agent" => %{"agent_kind_by_state" => %{"In Progress" => "invalid"}}
        })

      assert {:error, {:invalid_workflow_config, msg}} = result
      assert msg =~ "agent_kind"
    end
  end

  describe "config schema claude_code" do
    test "parses claude_code config block" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude_code",
        claude_code_command: "/usr/local/bin/claude",
        claude_code_model: "claude-sonnet-4-20250514",
        claude_code_permission_mode: "plan",
        claude_code_turn_timeout_ms: 1_800_000,
        claude_code_stall_timeout_ms: 120_000
      )

      settings = Config.settings!()
      assert settings.claude_code.command == "/usr/local/bin/claude"
      assert settings.claude_code.model == "claude-sonnet-4-20250514"
      assert settings.claude_code.permission_mode == "plan"
      assert settings.claude_code.turn_timeout_ms == 1_800_000
      assert settings.claude_code.stall_timeout_ms == 120_000
    end

    test "uses defaults when claude_code block is omitted" do
      write_workflow_file!(Workflow.workflow_file_path())

      settings = Config.settings!()
      assert settings.claude_code.command == "claude"
      assert settings.claude_code.permission_mode == "dangerously-skip-permissions"
      assert settings.claude_code.model == nil
      assert settings.claude_code.turn_timeout_ms == 3_600_000
      assert settings.claude_code.stall_timeout_ms == 300_000
    end
  end
end
