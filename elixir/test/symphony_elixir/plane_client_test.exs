defmodule SymphonyElixir.PlaneClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Plane.Client

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :plane_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :plane_request_fun)
      else
        Application.put_env(:symphony_elixir, :plane_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "fetch_candidate_issues queries plane project metadata and normalizes work items" do
    Application.put_env(:symphony_elixir, :plane_request_fun, &fake_request/5)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_endpoint: nil,
      tracker_api_token: "plane-token",
      tracker_project_slug: nil,
      tracker_workspace_slug: "workspace-1",
      tracker_project_id: "project-1",
      tracker_active_states: ["Todo"],
      tracker_assignee: "user-1"
    )

    Process.put(:plane_responses, [
      {:ok, %{status: 200, body: plane_project_body()}},
      {:ok, %{status: 200, body: plane_states_body()}},
      {:ok, %{status: 200, body: plane_work_items_body("state-todo")}}
    ])

    assert {:ok, [issue]} = Client.fetch_candidate_issues()

    assert issue.id == "work-item-1"
    assert issue.identifier == "PLN-42"
    assert issue.title == "Implement Plane tracker"
    assert issue.description == "Use Plane as the tracker backend"
    assert issue.priority == 3
    assert issue.state == "Todo"
    assert issue.url == nil
    assert issue.assignee_id == "user-1"
    assert issue.labels == ["backend", "agent"]
    assert issue.assigned_to_worker == true

    {:ok, expected_created_at, 0} = DateTime.from_iso8601("2026-03-12T00:00:00Z")
    {:ok, expected_updated_at, 0} = DateTime.from_iso8601("2026-03-12T01:00:00Z")

    assert issue.created_at == expected_created_at
    assert issue.updated_at == expected_updated_at

    assert_received {:plane_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1", _headers, nil, nil}
    assert_received {:plane_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states", _headers, nil, nil}

    assert_received {:plane_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/work-items", _headers, query, nil}

    assert query == %{
             "assignee" => "user-1",
             "expand" => "assignees,labels,state,project",
             "per_page" => 100,
             "state" => "state-todo"
           }
  end

  test "fetch_issue_states_by_ids preserves requested order and skips missing work items" do
    Application.put_env(:symphony_elixir, :plane_request_fun, &fake_request/5)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_endpoint: nil,
      tracker_api_token: "plane-token",
      tracker_project_slug: nil,
      tracker_workspace_slug: "workspace-1",
      tracker_project_id: "project-1"
    )

    Process.put(:plane_responses, [
      {:ok, %{status: 200, body: plane_project_body()}},
      {:ok, %{status: 200, body: plane_states_body()}},
      {:ok, %{status: 200, body: plane_work_item_body("work-item-2", 84, "state-done")}},
      {:ok, %{status: 404, body: %{"detail" => "Not found"}}},
      {:ok, %{status: 200, body: plane_work_item_body("work-item-1", 42, "state-todo")}}
    ])

    assert {:ok, issues} = Client.fetch_issue_states_by_ids(["work-item-2", "missing-item", "work-item-1"])
    assert Enum.map(issues, & &1.id) == ["work-item-2", "work-item-1"]
    assert Enum.map(issues, & &1.identifier) == ["PLN-84", "PLN-42"]
  end

  test "create_comment and update_issue_state use plane REST endpoints" do
    Application.put_env(:symphony_elixir, :plane_request_fun, &fake_request/5)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_endpoint: nil,
      tracker_api_token: "plane-token",
      tracker_project_slug: nil,
      tracker_workspace_slug: "workspace-1",
      tracker_project_id: "project-1"
    )

    Process.put(:plane_responses, [
      {:ok, %{status: 201, body: %{"id" => "comment-1"}}},
      {:ok, %{status: 200, body: plane_project_body()}},
      {:ok, %{status: 200, body: plane_states_body()}},
      {:ok, %{status: 200, body: %{"id" => "work-item-1"}}}
    ])

    assert :ok = Client.create_comment("work-item-1", "Looks <good>\nnow")

    assert_received {:plane_request, :post, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/work-items/work-item-1/comments", _headers, nil, comment_body}
    assert comment_body == %{"comment_html" => "<p>Looks &lt;good&gt;<br>now</p>"}

    assert :ok = Client.update_issue_state("work-item-1", "Done")

    assert_received {:plane_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1", _headers, nil, nil}
    assert_received {:plane_request, :get, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/states", _headers, nil, nil}
    assert_received {:plane_request, :patch, "https://api.plane.so/api/v1/workspaces/workspace-1/projects/project-1/work-items/work-item-1", _headers, nil, patch_body}
    assert patch_body == %{"state" => "state-done"}
  end

  defp fake_request(method, url, headers, query, body) do
    send(self(), {:plane_request, method, url, headers, query, body})

    case Process.get(:plane_responses) do
      [response | rest] ->
        Process.put(:plane_responses, rest)
        response

      other ->
        other || {:error, :missing_fake_plane_response}
    end
  end

  defp plane_project_body do
    %{
      "id" => "project-1",
      "name" => "Plane Project",
      "identifier" => "PLN"
    }
  end

  defp plane_states_body do
    %{
      "results" => [
        %{"id" => "state-todo", "name" => "Todo", "group" => "unstarted", "color" => "#999999"},
        %{"id" => "state-done", "name" => "Done", "group" => "completed", "color" => "#00ff00"}
      ]
    }
  end

  defp plane_work_items_body(state_id) do
    %{
      "results" => [plane_work_item_body("work-item-1", 42, state_id)],
      "next_cursor" => "",
      "next_page_results" => false
    }
  end

  defp plane_work_item_body(work_item_id, sequence_id, state_id) do
    %{
      "id" => work_item_id,
      "name" => "Implement Plane tracker",
      "description_html" => "<p>Use Plane as the tracker backend</p>",
      "description_stripped" => "Use Plane as the tracker backend",
      "priority" => "medium",
      "state" => %{"id" => state_id, "name" => if(state_id == "state-done", do: "Done", else: "Todo")},
      "sequence_id" => sequence_id,
      "project" => %{"id" => "project-1", "identifier" => "PLN"},
      "assignees" => [%{"id" => "user-1", "display_name" => "Agent User"}],
      "labels" => [%{"id" => "label-1", "name" => "Backend"}, %{"id" => "label-2", "name" => "Agent"}],
      "created_at" => "2026-03-12T00:00:00Z",
      "updated_at" => "2026-03-12T01:00:00Z"
    }
  end
end
