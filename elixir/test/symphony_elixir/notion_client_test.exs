defmodule SymphonyElixir.NotionClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notion.Client

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :notion_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :notion_request_fun)
      else
        Application.put_env(:symphony_elixir, :notion_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "fetch_candidate_issues queries a notion data source and normalizes pages" do
    Application.put_env(:symphony_elixir, :notion_request_fun, &fake_request/4)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_api_token: "notion-token",
      tracker_project_slug: nil,
      tracker_data_source_id: "source-123",
      tracker_active_states: ["Todo"],
      tracker_assignee: "user-1",
      tracker_assignee_property: "Assignee"
    )

    Process.put(:notion_responses, [
      {:ok, %{status: 200, body: notion_data_source_body("status")}},
      {:ok, %{status: 200, body: notion_query_body("status")}}
    ])

    assert {:ok, [issue]} = Client.fetch_candidate_issues()

    assert issue.id == "page-1"
    assert issue.identifier == "NT-1"
    assert issue.title == "Implement tracker"
    assert issue.description == "Pull tasks from Notion"
    assert issue.priority == 2
    assert issue.state == "In Progress"
    assert issue.url == "https://notion.so/page-1"
    assert issue.assignee_id == "user-1"
    assert issue.labels == ["backend", "agent"]
    assert issue.assigned_to_worker == true

    {:ok, expected_created_at, 0} = DateTime.from_iso8601("2026-03-12T00:00:00Z")
    {:ok, expected_updated_at, 0} = DateTime.from_iso8601("2026-03-12T01:00:00Z")

    assert issue.created_at == expected_created_at
    assert issue.updated_at == expected_updated_at

    assert_received {:notion_request, :get, "https://api.notion.com/v1/data_sources/source-123", _headers, nil}

    assert_received {:notion_request, :post, "https://api.notion.com/v1/data_sources/source-123/query", _headers, body}

    assert body["filter"] == %{
             "status" => %{"equals" => "Todo"},
             "property" => "Status"
           }
  end

  test "fetch_issue_states_by_ids preserves requested order and skips missing pages" do
    Application.put_env(:symphony_elixir, :notion_request_fun, &fake_request/4)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_api_token: "notion-token",
      tracker_project_slug: nil,
      tracker_data_source_id: "source-123"
    )

    Process.put(:notion_responses, [
      {:ok, %{status: 200, body: notion_data_source_body("status")}},
      {:ok, %{status: 200, body: notion_page_body("page-2", "NT-2", "Done")}},
      {:ok, %{status: 404, body: %{"message" => "Object not found"}}},
      {:ok, %{status: 200, body: notion_page_body("page-1", "NT-1", "Todo")}}
    ])

    assert {:ok, issues} = Client.fetch_issue_states_by_ids(["page-2", "missing-page", "page-1"])
    assert Enum.map(issues, & &1.id) == ["page-2", "page-1"]
    assert Enum.map(issues, & &1.identifier) == ["NT-2", "NT-1"]
  end

  test "create_comment and update_issue_state use notion REST endpoints" do
    Application.put_env(:symphony_elixir, :notion_request_fun, &fake_request/4)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "notion",
      tracker_endpoint: nil,
      tracker_api_token: "notion-token",
      tracker_project_slug: nil,
      tracker_data_source_id: "source-123",
      tracker_status_property: "Stage"
    )

    Process.put(:notion_responses, [
      {:ok, %{status: 200, body: %{"id" => "comment-1"}}},
      {:ok, %{status: 200, body: notion_data_source_body("select", "Stage")}},
      {:ok, %{status: 200, body: %{"id" => "page-1"}}}
    ])

    assert :ok = Client.create_comment("page-1", "Looks good")

    assert_received {:notion_request, :post, "https://api.notion.com/v1/comments", _headers, comment_body}
    assert comment_body["parent"] == %{"page_id" => "page-1"}
    assert get_in(comment_body, ["rich_text", Access.at(0), "text", "content"]) == "Looks good"

    assert :ok = Client.update_issue_state("page-1", "Done")

    assert_received {:notion_request, :get, "https://api.notion.com/v1/data_sources/source-123", _headers, nil}

    assert_received {:notion_request, :patch, "https://api.notion.com/v1/pages/page-1", _headers, patch_body}

    assert patch_body == %{
             "properties" => %{
               "Stage" => %{
                 "select" => %{"name" => "Done"}
               }
             }
           }
  end

  defp fake_request(method, url, headers, body) do
    send(self(), {:notion_request, method, url, headers, body})

    case Process.get(:notion_responses) do
      [response | rest] ->
        Process.put(:notion_responses, rest)
        response

      other ->
        other || {:error, :missing_fake_notion_response}
    end
  end

  defp notion_data_source_body(status_type, status_name \\ "Status") do
    %{
      "id" => "source-123",
      "properties" => %{
        "Task" => %{"id" => "task", "name" => "Task", "type" => "title"},
        status_name => %{"id" => "stage", "name" => status_name, "type" => status_type},
        "Identifier" => %{"id" => "identifier", "name" => "Identifier", "type" => "rich_text"},
        "Description" => %{"id" => "description", "name" => "Description", "type" => "rich_text"},
        "Labels" => %{"id" => "labels", "name" => "Labels", "type" => "multi_select"},
        "Priority" => %{"id" => "priority", "name" => "Priority", "type" => "number"},
        "Assignee" => %{"id" => "assignee", "name" => "Assignee", "type" => "people"}
      }
    }
  end

  defp notion_query_body(status_type) do
    %{
      "results" => [notion_page_body("page-1", "NT-1", "In Progress", status_type)],
      "has_more" => false,
      "next_cursor" => nil
    }
  end

  defp notion_page_body(page_id, identifier, state_name, status_type \\ "status") do
    %{
      "object" => "page",
      "id" => page_id,
      "url" => "https://notion.so/#{page_id}",
      "created_time" => "2026-03-12T00:00:00Z",
      "last_edited_time" => "2026-03-12T01:00:00Z",
      "properties" => %{
        "Task" => %{
          "id" => "task",
          "type" => "title",
          "title" => [%{"plain_text" => "Implement tracker"}]
        },
        "Status" => %{
          "id" => "stage",
          "type" => status_type,
          status_type => %{"name" => state_name}
        },
        "Stage" => %{
          "id" => "stage",
          "type" => status_type,
          status_type => %{"name" => state_name}
        },
        "Identifier" => %{
          "id" => "identifier",
          "type" => "rich_text",
          "rich_text" => [%{"plain_text" => identifier}]
        },
        "Description" => %{
          "id" => "description",
          "type" => "rich_text",
          "rich_text" => [%{"plain_text" => "Pull tasks from Notion"}]
        },
        "Labels" => %{
          "id" => "labels",
          "type" => "multi_select",
          "multi_select" => [%{"name" => "Backend"}, %{"name" => "Agent"}]
        },
        "Priority" => %{
          "id" => "priority",
          "type" => "number",
          "number" => 2
        },
        "Assignee" => %{
          "id" => "assignee",
          "type" => "people",
          "people" => [%{"id" => "user-1"}]
        }
      }
    }
  end
end
