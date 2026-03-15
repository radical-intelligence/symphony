defmodule Mix.Tasks.Plane.SyncStatesTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Plane.SyncStates

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("plane.sync_states")

    previous_request_fun = Application.get_env(:symphony_elixir, :plane_request_fun)
    previous_api_key = System.get_env("PLANE_API_KEY")
    previous_workspace_slug = System.get_env("PLANE_WORKSPACE_SLUG")
    previous_project_id = System.get_env("PLANE_PROJECT_ID")
    previous_endpoint = System.get_env("SYMPHONY_LIVE_PLANE_ENDPOINT")

    on_exit(fn ->
      restore_env("PLANE_API_KEY", previous_api_key)
      restore_env("PLANE_WORKSPACE_SLUG", previous_workspace_slug)
      restore_env("PLANE_PROJECT_ID", previous_project_id)
      restore_env("SYMPHONY_LIVE_PLANE_ENDPOINT", previous_endpoint)

      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :plane_request_fun)
      else
        Application.put_env(:symphony_elixir, :plane_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        SyncStates.run(["--help"])
      end)

    assert output =~ "mix plane.sync_states"
    assert output =~ "--with-review-loop"
  end

  test "fails when required env is missing" do
    System.delete_env("PLANE_API_KEY")
    System.delete_env("PLANE_WORKSPACE_SLUG")
    System.delete_env("PLANE_PROJECT_ID")

    assert_raise Mix.Error, ~r/Missing required Plane configuration/, fn ->
      SyncStates.run([])
    end
  end

  test "dry-run prints recommendations without applying changes" do
    configure_env!()
    Application.put_env(:symphony_elixir, :plane_request_fun, &fake_request/5)

    Process.put(:plane_sync_responses, [
      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{"id" => "state-todo", "name" => "Todo", "group" => "unstarted"},
             %{"id" => "state-progress", "name" => "In Progress", "group" => "started"},
             %{"id" => "state-done", "name" => "Done", "group" => "completed"},
             %{"id" => "state-canceled", "name" => "Canceled", "group" => "cancelled"}
           ]
         }
       }}
    ])

    output =
      capture_io(fn ->
        SyncStates.run(["--dry-run"])
      end)

    assert output =~ "Required Symphony states"
    assert output =~ "Create: create missing Backlog state in backlog"
    assert output =~ ~s(Update: rename "Canceled" to "Cancelled")
    assert output =~ "Optional review-loop states (not applied unless --with-review-loop)"
    assert output =~ "Dry run only. No Plane changes were applied."

    assert_received {:plane_sync_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states/", _headers, nil, nil}
    refute_received {:plane_sync_request, :post, _url, _headers, _query, _body}
    refute_received {:plane_sync_request, :patch, _url, _headers, _query, _body}
  end

  test "applies required and optional review-loop changes" do
    configure_env!()
    Application.put_env(:symphony_elixir, :plane_request_fun, &fake_request/5)

    Process.put(:plane_sync_responses, [
      {:ok,
       %{
         status: 200,
         body: %{
           "results" => [
             %{"id" => "state-backlog", "name" => "Backlog", "group" => "backlog"},
             %{"id" => "state-todo", "name" => "Todo", "group" => "unstarted"},
             %{"id" => "state-progress", "name" => "In Progress", "group" => "started"},
             %{"id" => "state-done", "name" => "Done", "group" => "completed"},
             %{"id" => "state-canceled", "name" => "Canceled", "group" => "cancelled"}
           ]
         }
       }},
      {:ok, %{status: 200, body: %{"id" => "state-canceled", "name" => "Cancelled", "group" => "cancelled"}}},
      {:ok, %{status: 200, body: %{"id" => "state-review", "name" => "Human Review", "group" => "unstarted"}}},
      {:ok, %{status: 200, body: %{"id" => "state-merging", "name" => "Merging", "group" => "started"}}},
      {:ok, %{status: 200, body: %{"id" => "state-rework", "name" => "Rework", "group" => "started"}}}
    ])

    output =
      capture_io(fn ->
        SyncStates.run(["--with-review-loop"])
      end)

    assert output =~ "Applying 4 Plane state change(s)..."
    assert output =~ "Applied update: Cancelled [cancelled]"
    assert output =~ "Applied create: Human Review [unstarted]"
    assert output =~ "Applied create: Merging [started]"
    assert output =~ "Applied create: Rework [started]"

    assert_received {:plane_sync_request, :patch, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states/state-canceled/", _headers, nil, patch_body}
    assert patch_body == %{"name" => "Cancelled"}

    assert_received {:plane_sync_request, :post, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states/", _headers, nil,
                     %{"name" => "Human Review", "group" => "unstarted", "color" => "#F59E0B"}}

    assert_received {:plane_sync_request, :post, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states/", _headers, nil,
                     %{"name" => "Merging", "group" => "started", "color" => "#7C3AED"}}

    assert_received {:plane_sync_request, :post, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states/", _headers, nil,
                     %{"name" => "Rework", "group" => "started", "color" => "#DC2626"}}
  end

  defp configure_env! do
    System.put_env("PLANE_API_KEY", "plane-token")
    System.put_env("PLANE_WORKSPACE_SLUG", "workspace-1")
    System.put_env("PLANE_PROJECT_ID", "project-1")
    System.delete_env("SYMPHONY_LIVE_PLANE_ENDPOINT")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp fake_request(method, url, headers, query, body) do
    send(self(), {:plane_sync_request, method, url, headers, query, body})

    case Process.get(:plane_sync_responses) do
      [response | rest] ->
        Process.put(:plane_sync_responses, rest)
        response

      other ->
        other || {:error, :missing_fake_plane_response}
    end
  end
end
