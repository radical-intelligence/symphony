defmodule SymphonyElixir.ClaudeCode.McpConfig do
  @moduledoc """
  Writes a `.mcp.json` file into the workspace so Claude Code auto-discovers
  the tracker's MCP server with credentials injected via env vars.

  If the workspace already contains a `.mcp.json` (e.g. from the cloned repo),
  Symphony merges its tracker server entry without overwriting existing servers.
  """

  alias SymphonyElixir.Config

  @config_filename ".mcp.json"
  @server_key "symphony-tracker"

  @spec write_mcp_config(Path.t()) :: {:ok, Path.t()} | :skip | {:error, term()}
  def write_mcp_config(workspace) do
    settings = Config.settings!()
    tracker = settings.tracker
    claude_code = settings.claude_code

    server_entry =
      case claude_code.tracker_mcp_command do
        cmd when is_binary(cmd) and cmd != "" ->
          build_server_entry(cmd, claude_code.tracker_mcp_args, tracker)

        _ ->
          default_tracker_mcp(tracker)
      end

    case server_entry do
      nil ->
        :skip

      entry ->
        path = Path.join(workspace, @config_filename)
        write_merged_config(path, entry)
    end
  rescue
    error in [File.Error] ->
      {:error, {:mcp_config_write_failed, Exception.message(error)}}
  end

  @spec build_mcp_json() :: {:ok, String.t()} | :skip
  def build_mcp_json do
    settings = Config.settings!()
    tracker = settings.tracker
    claude_code = settings.claude_code

    server_entry =
      case claude_code.tracker_mcp_command do
        cmd when is_binary(cmd) and cmd != "" ->
          build_server_entry(cmd, claude_code.tracker_mcp_args, tracker)

        _ ->
          default_tracker_mcp(tracker)
      end

    case server_entry do
      nil -> :skip
      entry ->
        config = %{"mcpServers" => %{@server_key => entry}}
        {:ok, Jason.encode!(config, pretty: true)}
    end
  end

  @spec cleanup_mcp_config(Path.t()) :: :ok
  def cleanup_mcp_config(workspace) do
    path = Path.join(workspace, @config_filename)

    case read_existing_config(path) do
      {:ok, existing} ->
        cleaned = Map.update(existing, "mcpServers", %{}, &Map.delete(&1, @server_key))

        if cleaned["mcpServers"] == %{} do
          File.rm(path)
        else
          File.write!(path, Jason.encode!(cleaned, pretty: true))
        end

      _ ->
        :ok
    end

    :ok
  end

  # Auto-configure the official Plane MCP server with PAT auth via mcp-remote.
  # See https://developers.plane.so/dev-tools/mcp-server
  defp default_tracker_mcp(%{kind: "plane", api_key: api_key, workspace_slug: ws_slug})
       when is_binary(api_key) and is_binary(ws_slug) do
    %{
      "command" => "npx",
      "args" => [
        "mcp-remote@latest",
        "https://mcp.plane.so/http/api-key/mcp",
        "--header",
        "Authorization: Bearer #{api_key}",
        "--header",
        "X-Workspace-slug: #{ws_slug}"
      ]
    }
  end

  defp default_tracker_mcp(_tracker), do: nil

  defp build_server_entry(command, args, tracker) do
    entry = %{"command" => command}
    entry = if args != [], do: Map.put(entry, "args", args), else: entry
    env = tracker_env(tracker)
    if env != %{}, do: Map.put(entry, "env", env), else: entry
  end

  defp write_merged_config(path, server_entry) do
    existing =
      case read_existing_config(path) do
        {:ok, config} -> config
        _ -> %{}
      end

    servers = Map.get(existing, "mcpServers", %{})
    merged = Map.put(existing, "mcpServers", Map.put(servers, @server_key, server_entry))

    File.write!(path, Jason.encode!(merged, pretty: true))
    {:ok, path}
  end

  defp read_existing_config(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode(content)
      {:error, _} -> :error
    end
  end

  defp tracker_env(tracker) do
    env = %{}

    env =
      case tracker.kind do
        "linear" -> maybe_put(env, "LINEAR_API_KEY", tracker.api_key)
        "plane" -> maybe_put(env, "PLANE_API_KEY", tracker.api_key)
        "notion" -> maybe_put(env, "NOTION_API_KEY", tracker.api_key)
        _ -> env
      end

    case tracker.kind do
      "plane" ->
        env
        |> maybe_put("PLANE_WORKSPACE_SLUG", tracker.workspace_slug)
        |> maybe_put("PLANE_PROJECT_ID", tracker.project_id)

      "notion" ->
        maybe_put(env, "NOTION_DATA_SOURCE_ID", tracker.data_source_id)

      _ ->
        env
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)
end
