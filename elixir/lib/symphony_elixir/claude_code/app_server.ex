defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc """
  Agent backend for the Claude Code CLI.

  Unlike the Codex app-server which maintains a persistent JSON-RPC session,
  Claude Code is invoked as a fresh process per turn with `--output-format stream-json`.
  Session continuity across turns is achieved via the `--resume <session_id>` flag.
  """

  @behaviour SymphonyElixir.Agent

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          worker_host: String.t() | nil,
          session_id: String.t() | nil,
          wrote_mcp?: boolean()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host) do
      wrote_mcp? = write_remote_mcp_config(expanded_workspace, worker_host)

      {:ok,
       %{
         workspace: expanded_workspace,
         worker_host: worker_host,
         session_id: nil,
         wrote_mcp?: wrote_mcp?
       }}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    timeout_ms = Config.settings!().claude_code.turn_timeout_ms

    cli = build_cli_args(session)

    with {:ok, port} <- start_port(session.workspace, session.worker_host, cli, prompt) do
      case await_completion(port, on_message, timeout_ms) do
        {:ok, %{is_error: true} = result} ->
          Logger.warning("Claude Code turn returned is_error=true: #{inspect(result[:result] || result[:error] || "unknown")}")
          {:error, {:claude_code_error, result}}

        {:ok, result} ->
          session_id = result[:session_id] || session.session_id
          {:ok, Map.merge(result, %{session_id: session_id})}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{workspace: workspace, wrote_mcp?: true}) when is_binary(workspace) do
    SymphonyElixir.ClaudeCode.McpConfig.cleanup_mcp_config(workspace)
    :ok
  end

  def stop_session(_session), do: :ok

  # -- Command building --

  defp build_cli_args(%{session_id: session_id}) do
    claude_code = Config.settings!().claude_code

    args = [
      claude_code.command,
      "-p",
      "--verbose",
      "--output-format", "stream-json"
    ]

    args =
      case claude_code.permission_mode do
        "dangerously-skip-permissions" -> args ++ ["--dangerously-skip-permissions"]
        mode when is_binary(mode) and mode != "" -> args ++ ["--permission-mode", mode]
        _ -> args
      end

    args = if claude_code.model, do: args ++ ["--model", claude_code.model], else: args
    args = if session_id, do: args ++ ["--resume", session_id], else: args

    Enum.join(args, " ")
  end

  # -- Port management --

  defp start_port(workspace, nil, cli, prompt) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      # Use a heredoc to pipe the prompt to claude via stdin. The heredoc
      # delimiter ensures EOF is sent after the prompt without shell escaping
      # issues.
      command = "cat <<'__SYMPHONY_PROMPT_EOF__' | #{cli}\n#{prompt}\n__SYMPHONY_PROMPT_EOF__"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, cli, prompt) when is_binary(worker_host) do
    b64_prompt = Base.encode64(prompt)

    # The remote command runs inside bash -lc '...' (via SSH.remote_shell_command).
    # Auth env vars are exported inside the bash -lc command. The token values
    # are alphanumeric with hyphens/underscores, so they survive single-quote
    # escaping without issues.
    env_exports = auth_env_exports()

    remote_command =
      [
        env_exports,
        "cd #{shell_escape(workspace)}",
        "_pf=$(mktemp)",
        "printf '%s' '#{b64_prompt}' | base64 -d > \"$_pf\"",
        "#{cli} < \"$_pf\" | cat -u",
        "_rc=${PIPESTATUS[0]:-$?}",
        "rm -f \"$_pf\"",
        "exit $_rc"
      ]
      |> Enum.join(" && ")

    start_unbuffered_ssh_port(worker_host, remote_command)
  end

  defp start_unbuffered_ssh_port(worker_host, command) do
    # Write the remote_shell command to a file, then have a wrapper script
    # read it and pass it as a single quoted argument to SSH. This preserves
    # the bash -lc quoting without any shell interpretation.
    ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")
    remote_shell = SSH.remote_shell_command(command)
    trimmed_host = String.trim(worker_host)

    {destination, port_arg} =
      case Regex.run(~r/^(.*):(\d+)$/, trimmed_host, capture: :all_but_first) do
        [dest, p] -> {dest, "-p #{p} "}
        _ -> {trimmed_host, ""}
      end

    config_arg = if ssh_config, do: "-F '#{ssh_config}' ", else: ""

    base_id = System.unique_integer([:positive])
    wrapper = Path.join(System.tmp_dir!(), "symphony-ssh-#{base_id}.sh")
    cmd_file = Path.join(System.tmp_dir!(), "symphony-ssh-#{base_id}.cmd")

    File.write!(cmd_file, remote_shell)

    script = """
    #!/bin/sh
    _cmd="$(cat '#{cmd_file}')"
    rm -f '#{cmd_file}'
    exec ssh #{config_arg}-T #{port_arg}#{destination} "$_cmd"
    """

    File.write!(wrapper, script)
    File.chmod!(wrapper, 0o755)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(wrapper)},
        [:binary, :exit_status, :stderr_to_stdout, line: @port_line_bytes]
      )

    Task.start(fn ->
      Process.sleep(300_000)
      File.rm(wrapper)
    end)

    {:ok, port}
  end

  defp write_remote_mcp_config(workspace, nil) do
    # Local worker — write directly
    case SymphonyElixir.ClaudeCode.McpConfig.write_mcp_config(workspace) do
      {:ok, _path} -> true
      _ -> false
    end
  end

  defp write_remote_mcp_config(workspace, worker_host) when is_binary(worker_host) do
    # SSH worker — generate the JSON locally then write it to the remote host
    case SymphonyElixir.ClaudeCode.McpConfig.build_mcp_json() do
      {:ok, json} ->
        b64_json = Base.encode64(json)
        mcp_path = Path.join(workspace, ".mcp.json")
        cmd = "printf '%s' '#{b64_json}' | base64 -d > #{shell_escape(mcp_path)}"

        case SSH.run(worker_host, cmd, stderr_to_stdout: true) do
          {:ok, {_, 0}} -> true
          _ -> false
        end

      :skip ->
        false
    end
  end

  defp auth_env_exports do
    # Export auth env vars inside the bash -lc command. The token values are
    # read from the Elixir runtime and embedded directly. They're safe for
    # single-quote shell escaping because they're alphanumeric + hyphens.
    ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"]
    |> Enum.flat_map(fn env_name ->
      case System.get_env(env_name) do
        nil -> []
        value -> ["export #{env_name}=#{value}"]
      end
    end)
    |> Enum.join(" && ")
  end

  # -- Event stream receive loop --

  defp await_completion(port, on_message, timeout_ms) do
    receive_loop(port, on_message, timeout_ms, "", %{})
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_event_line(port, on_message, complete_line, timeout_ms, acc)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending_line <> to_string(chunk), acc)

      {^port, {:exit_status, 0}} ->
        Logger.info("Claude Code port exited with status 0 acc=#{inspect(Map.keys(acc))}")
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude Code port exited with status #{status}")
        {:error, {:port_exit, status}}

      {^port, :eof} ->
        Logger.info("Claude Code port EOF acc=#{inspect(Map.keys(acc))}")
        {:ok, acc}

    after
      timeout_ms ->
        Logger.warning("Claude Code turn timed out after #{timeout_ms}ms")
        safe_close_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_event_line(port, on_message, data, timeout_ms, acc) do
    case Jason.decode(data) do
      {:ok, %{"type" => "system"} = event} ->
        session_id = get_in(event, ["session_id"]) || acc[:session_id]
        emit(on_message, :session_started, event, %{session_id: session_id})
        receive_loop(port, on_message, timeout_ms, "", Map.put(acc, :session_id, session_id))

      {:ok, %{"type" => "assistant"} = event} ->
        acc = extract_token_usage(acc, event)
        emit(on_message, :notification, event, %{
          session_id: acc[:session_id],
          usage: %{input_tokens: acc[:input_tokens] || 0, output_tokens: acc[:output_tokens] || 0, total_tokens: (acc[:input_tokens] || 0) + (acc[:output_tokens] || 0)}
        })
        receive_loop(port, on_message, timeout_ms, "", acc)

      {:ok, %{"type" => "result"} = event} ->
        acc = extract_result(acc, event)
        acc = extract_token_usage(acc, event)
        usage = acc_usage(acc)

        if event["is_error"] do
          emit(on_message, :turn_failed, event, %{session_id: acc[:session_id], usage: usage})
        else
          emit(on_message, :turn_completed, event, %{session_id: acc[:session_id], usage: usage})
        end

        receive_loop(port, on_message, timeout_ms, "", acc)

      {:ok, %{"type" => "rate_limit_event"}} ->
        # Rate limit events have no useful content for the dashboard
        receive_loop(port, on_message, timeout_ms, "", acc)

      {:ok, event} ->
        acc = extract_result(acc, event)
        acc = extract_token_usage(acc, event)
        usage = acc_usage(acc)

        if event["is_error"] do
          emit(on_message, :turn_failed, event, %{session_id: acc[:session_id], usage: usage})
        else
          emit(on_message, :turn_completed, event, %{session_id: acc[:session_id], usage: usage})
        end

        receive_loop(port, on_message, timeout_ms, "", acc)

      {:error, _} ->
        log_non_json_line(data)
        receive_loop(port, on_message, timeout_ms, "", acc)
    end
  end

  defp extract_token_usage(acc, event) do
    case get_in(event, ["message", "usage"]) || event["usage"] do
      %{"input_tokens" => input, "output_tokens" => output} = usage ->
        # Include cache tokens in the input count since they represent
        # actual context processed by the model.
        cache_read = usage["cache_read_input_tokens"] || 0
        cache_create = usage["cache_creation_input_tokens"] || 0
        total_input = input + cache_read + cache_create

        acc
        |> Map.update(:input_tokens, total_input, &(&1 + total_input))
        |> Map.update(:output_tokens, output, &(&1 + output))

      _ ->
        acc
    end
  end

  defp extract_result(acc, event) do
    acc
    |> Map.put(:cost_usd, event["total_cost_usd"] || event["cost_usd"])
    |> Map.put(:duration_ms, event["duration_ms"])
    |> Map.put(:num_turns, event["num_turns"])
    |> Map.put(:session_id, event["session_id"] || acc[:session_id])
    |> Map.put(:result, event["result"])
    |> Map.put(:is_error, event["is_error"] || false)
  end

  defp emit(on_message, event_type, payload, extras \\ %{})
       when is_function(on_message, 1) do
    # Match the Codex event format so the orchestrator's codex_worker_update
    # handler recognizes the message. Include session_id and usage at the top
    # level for the orchestrator's token tracking and session display.
    msg =
      Map.merge(extras, %{
        event: event_type,
        method: event_type_to_method(event_type),
        timestamp: System.system_time(:millisecond),
        message: payload
      })

    on_message.(msg)
    :ok
  rescue
    _ -> :ok
  end

  defp event_type_to_method(:session_started), do: "session/started"
  defp event_type_to_method(:turn_completed), do: "turn/completed"
  defp event_type_to_method(:turn_failed), do: "turn/failed"
  defp event_type_to_method(:notification), do: "notification"
  defp event_type_to_method(other), do: to_string(other)

  defp acc_usage(acc) do
    input = acc[:input_tokens] || 0
    output = acc[:output_tokens] || 0
    %{input_tokens: input, output_tokens: output, total_tokens: input + output}
  end

  # -- Workspace validation (shared pattern with Codex.AppServer) --

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp safe_close_port(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp log_non_json_line(data) do
    truncated =
      if byte_size(data) > @max_stream_log_bytes do
        binary_part(data, 0, @max_stream_log_bytes) <> "..."
      else
        data
      end

    Logger.debug("claude-code non-JSON output: #{truncated}")
  end
end
