defmodule SymphonyElixir.ClaudeCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer

  describe "start_session/2" do
    test "returns session with workspace and nil session_id" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-claude-code-test-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "TEST-1")

      try do
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code"
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        assert session.workspace == workspace
        assert session.session_id == nil
        assert session.worker_host == nil
      after
        File.rm_rf(workspace_root)
      end
    end

    test "rejects workspace outside root" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude_code")

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               AppServer.start_session("/tmp/not-a-symphony-workspace")
    end
  end

  describe "run_turn/4 event stream parsing" do
    test "parses system, assistant, and result events from a fake claude process" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-claude-code-turn-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "TURN-1")
      fake_claude = Path.join(workspace_root, "fake-claude")

      try do
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        # Read prompt from stdin
        cat > /dev/null
        # Emit events
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-abc123","model":"claude-sonnet-4-20250514"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]},"usage":{"input_tokens":100,"output_tokens":50}}'
        printf '%s\\n' '{"type":"result","subtype":"success","cost_usd":0.01,"duration_ms":5000,"num_turns":1,"is_error":false}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code",
          claude_code_command: fake_claude
        )

        session = %{
          workspace: workspace,
          worker_host: nil,
          session_id: nil,
          wrote_mcp?: false
        }

        events = :ets.new(:test_events, [:bag, :public])

        on_message = fn msg ->
          :ets.insert(events, {msg.type, msg})
        end

        assert {:ok, result} =
                 AppServer.run_turn(session, "Do the task", %{}, on_message: on_message)

        assert result[:session_id] == "sess-abc123"
        assert result[:cost_usd] == 0.01
        assert result[:duration_ms] == 5000
        assert result[:is_error] == false
        assert result[:input_tokens] == 100
        assert result[:output_tokens] == 50

        assert :ets.lookup(events, :session_started) != []
        assert :ets.lookup(events, :turn_completed) != []

        :ets.delete(events)
      after
        File.rm_rf(workspace_root)
      end
    end

    test "captures session_id for resume on subsequent turns" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-claude-code-resume-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "RESUME-1")
      fake_claude = Path.join(workspace_root, "fake-claude-resume")
      trace_file = Path.join(workspace_root, "claude-args.trace")

      try do
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        # Write all args to trace file
        printf '%s\\n' "$*" >> "#{trace_file}"
        cat > /dev/null
        printf '%s\\n' '{"type":"system","session_id":"sess-resume-001"}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code",
          claude_code_command: fake_claude
        )

        session = %{
          workspace: workspace,
          worker_host: nil,
          session_id: nil,
          wrote_mcp?: false
        }

        # First turn — no --resume flag
        assert {:ok, result1} = AppServer.run_turn(session, "First turn", %{})
        assert result1[:session_id] == "sess-resume-001"

        # Second turn — should include --resume
        session2 = %{session | session_id: result1[:session_id]}
        assert {:ok, _result2} = AppServer.run_turn(session2, "Second turn", %{})

        # Verify the second invocation included --resume
        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)
        assert length(lines) == 2
        refute String.contains?(Enum.at(lines, 0), "--resume")
        assert String.contains?(Enum.at(lines, 1), "--resume sess-resume-001")
      after
        File.rm_rf(workspace_root)
      end
    end

    test "handles error result events" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-claude-code-error-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "ERR-1")
      fake_claude = Path.join(workspace_root, "fake-claude-error")

      try do
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        cat > /dev/null
        printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"error":"rate limited"}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code",
          claude_code_command: fake_claude
        )

        session = %{
          workspace: workspace,
          worker_host: nil,
          session_id: nil,
          wrote_mcp?: false
        }

        on_message = fn msg ->
          send(self(), {:event, msg.type})
        end

        assert {:error, {:claude_code_error, result}} =
                 AppServer.run_turn(session, "Do task", %{}, on_message: on_message)

        assert result[:is_error] == true
        assert_received {:event, :turn_failed}
      after
        File.rm_rf(workspace_root)
      end
    end

    test "handles non-JSON output gracefully" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-claude-code-nonjson-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "NJ-1")
      fake_claude = Path.join(workspace_root, "fake-claude-nonjson")

      try do
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        cat > /dev/null
        echo "Some debug output"
        echo "WARNING: something happened"
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code",
          claude_code_command: fake_claude
        )

        session = %{
          workspace: workspace,
          worker_host: nil,
          session_id: nil,
          wrote_mcp?: false
        }

        assert {:ok, result} = AppServer.run_turn(session, "Do task", %{})
        assert result[:is_error] == false
      after
        File.rm_rf(workspace_root)
      end
    end
  end

  describe "stop_session/1" do
    test "cleans up .mcp.json tracker entry when wrote_mcp? is true" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-claude-code-stop-#{System.unique_integer([:positive])}")

      try do
        File.mkdir_p!(workspace)
        config = %{"mcpServers" => %{"symphony-tracker" => %{"command" => "test"}}}
        File.write!(Path.join(workspace, ".mcp.json"), Jason.encode!(config))

        AppServer.stop_session(%{workspace: workspace, wrote_mcp?: true})
        refute File.exists?(Path.join(workspace, ".mcp.json"))
      after
        File.rm_rf(workspace)
      end
    end

    test "skips cleanup when wrote_mcp? is false" do
      assert :ok = AppServer.stop_session(%{workspace: "/tmp/fake", wrote_mcp?: false})
    end
  end
end
