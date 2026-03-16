defmodule SymphonyElixir.ClaudeCode.McpConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.McpConfig

  describe "write_mcp_config/1" do
    test "skips when tracker_mcp_command is not set" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-skip-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)
        write_workflow_file!(Workflow.workflow_file_path())

        assert :skip = McpConfig.write_mcp_config(workspace)
        refute File.exists?(Path.join(workspace, ".mcp.json"))
      after
        File.rm_rf(workspace)
      end
    end

    test "writes .mcp.json with tracker env for plane" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-plane-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "plane",
          tracker_api_token: "plane-key",
          tracker_workspace_slug: "my-ws",
          tracker_project_id: "proj-123",
          claude_code_command: "claude",
          claude_code_tracker_mcp_command: "plane-mcp-server",
          claude_code_tracker_mcp_args: ["--verbose"]
        )

        assert {:ok, path} = McpConfig.write_mcp_config(workspace)
        assert String.ends_with?(path, ".mcp.json")

        config = Jason.decode!(File.read!(path))
        server = config["mcpServers"]["symphony-tracker"]
        assert server["command"] == "plane-mcp-server"
        assert server["args"] == ["--verbose"]
        assert server["env"]["PLANE_API_KEY"] == "plane-key"
        assert server["env"]["PLANE_WORKSPACE_SLUG"] == "my-ws"
        assert server["env"]["PLANE_PROJECT_ID"] == "proj-123"
      after
        File.rm_rf(workspace)
      end
    end

    test "writes .mcp.json with tracker env for linear" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-linear-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          tracker_api_token: "lin-token",
          claude_code_command: "claude",
          claude_code_tracker_mcp_command: "npx",
          claude_code_tracker_mcp_args: ["@linear/mcp-server"]
        )

        assert {:ok, _path} = McpConfig.write_mcp_config(workspace)

        config = Jason.decode!(File.read!(Path.join(workspace, ".mcp.json")))
        server = config["mcpServers"]["symphony-tracker"]
        assert server["command"] == "npx"
        assert server["args"] == ["@linear/mcp-server"]
        assert server["env"]["LINEAR_API_KEY"] == "lin-token"
      after
        File.rm_rf(workspace)
      end
    end

    test "merges with existing .mcp.json without overwriting other servers" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-merge-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)

        existing = %{
          "mcpServers" => %{
            "my-custom-server" => %{"command" => "my-tool", "args" => ["--foo"]}
          }
        }

        File.write!(Path.join(workspace, ".mcp.json"), Jason.encode!(existing))

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "plane",
          tracker_api_token: "key",
          claude_code_command: "claude",
          claude_code_tracker_mcp_command: "plane-mcp"
        )

        assert {:ok, _path} = McpConfig.write_mcp_config(workspace)

        config = Jason.decode!(File.read!(Path.join(workspace, ".mcp.json")))
        assert config["mcpServers"]["my-custom-server"]["command"] == "my-tool"
        assert config["mcpServers"]["symphony-tracker"]["command"] == "plane-mcp"
      after
        File.rm_rf(workspace)
      end
    end
  end

  describe "cleanup_mcp_config/1" do
    test "removes only the symphony-tracker entry, preserves other servers" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-cleanup-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)

        config = %{
          "mcpServers" => %{
            "symphony-tracker" => %{"command" => "plane-mcp"},
            "other-server" => %{"command" => "other"}
          }
        }

        File.write!(Path.join(workspace, ".mcp.json"), Jason.encode!(config))

        McpConfig.cleanup_mcp_config(workspace)

        cleaned = Jason.decode!(File.read!(Path.join(workspace, ".mcp.json")))
        refute Map.has_key?(cleaned["mcpServers"], "symphony-tracker")
        assert cleaned["mcpServers"]["other-server"]["command"] == "other"
      after
        File.rm_rf(workspace)
      end
    end

    test "removes .mcp.json entirely when symphony-tracker was the only server" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-cleanup-only-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)

        config = %{"mcpServers" => %{"symphony-tracker" => %{"command" => "plane-mcp"}}}
        File.write!(Path.join(workspace, ".mcp.json"), Jason.encode!(config))

        McpConfig.cleanup_mcp_config(workspace)

        refute File.exists?(Path.join(workspace, ".mcp.json"))
      after
        File.rm_rf(workspace)
      end
    end

    test "succeeds when .mcp.json does not exist" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-mcp-cleanup-nofile-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      assert :ok = McpConfig.cleanup_mcp_config(workspace)
      File.rm_rf(workspace)
    end
  end
end
