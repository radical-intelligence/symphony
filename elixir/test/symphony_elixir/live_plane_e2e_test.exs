defmodule SymphonyElixir.LivePlaneE2ETest do
  use SymphonyElixir.TestSupport

  require Logger

  alias SymphonyElixir.{LiveE2ESupport, Plane.API, Plane.Client}

  @moduletag :live_e2e
  @moduletag :live_plane_e2e
  @moduletag timeout: 300_000

  @expand_fields "assignees,labels,state,project"
  @result_file "LIVE_PLANE_E2E_RESULT.txt"

  @live_plane_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_PLANE_E2E") != "1",
                                do: "set SYMPHONY_RUN_LIVE_PLANE_E2E=1 to enable the real Plane/Codex end-to-end test"
                              )
  @live_plane_e2e_backend System.get_env("SYMPHONY_LIVE_PLANE_E2E_BACKEND")
  @live_plane_e2e_local_skip_reason (
                                       cond do
                                         @live_plane_e2e_skip_reason ->
                                           @live_plane_e2e_skip_reason

                                         @live_plane_e2e_backend in [nil, "", "local", "all"] ->
                                           nil

                                         true ->
                                           "set SYMPHONY_LIVE_PLANE_E2E_BACKEND=local (or unset it) to enable the local-worker Plane live e2e test"
                                       end
                                     )
  @live_plane_e2e_ssh_skip_reason (
                                     cond do
                                       @live_plane_e2e_skip_reason ->
                                         @live_plane_e2e_skip_reason

                                       @live_plane_e2e_backend in [nil, "", "ssh", "all"] ->
                                         nil

                                       true ->
                                         "set SYMPHONY_LIVE_PLANE_E2E_BACKEND=ssh (or unset it) to enable the ssh-worker Plane live e2e test"
                                     end
                                   )

  @tag skip: @live_plane_e2e_local_skip_reason
  test "creates a real Plane project and work item with a local worker" do
    run_live_plane_work_item_flow!(:local)
  end

  @tag skip: @live_plane_e2e_ssh_skip_reason
  test "creates a real Plane project and work item with an ssh worker" do
    run_live_plane_work_item_flow!(:ssh)
  end

  defp run_live_plane_work_item_flow!(backend) when backend in [:local, :ssh] do
    workspace_slug = required_env!("PLANE_WORKSPACE_SLUG")
    run_id = "symphony-live-plane-e2e-#{backend}-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    worker_setup = LiveE2ESupport.live_worker_setup!(backend, run_id, test_root)
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
    project_ref = make_ref()

    File.mkdir_p!(workflow_root)
    Process.put(project_ref, nil)

    try do
      required_env!("PLANE_API_KEY")

      if is_pid(orchestrator_pid) do
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end

      Workflow.set_workflow_file_path(workflow_file)

      write_bootstrap_workflow!(workflow_file, worker_setup, workspace_slug)

      project =
        create_project!(
          workspace_slug,
          "Symphony Live Plane E2E #{backend} #{System.unique_integer([:positive])}",
          project_identifier()
        )

      project_id = project["id"]
      Process.put(project_ref, project_id)
      states = list_states!(workspace_slug, project_id)
      active_state = active_state!(states)

      work_item =
        create_work_item!(
          workspace_slug,
          project_id,
          active_state["id"],
          "Symphony live Plane e2e #{backend} work item for #{project["name"]}"
        )

      write_workflow_file!(workflow_file,
        tracker_kind: "plane",
        tracker_endpoint: live_plane_endpoint(),
        tracker_api_token: "$PLANE_API_KEY",
        tracker_project_slug: nil,
        tracker_workspace_slug: workspace_slug,
        tracker_project_id: project_id,
        tracker_active_states: active_state_names(states),
        tracker_terminal_states: terminal_state_names(states),
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 600_000,
        codex_stall_timeout_ms: 600_000,
        observability_enabled: false,
        prompt: live_prompt(project_id)
      )

      assert {:ok, [%Issue{} = issue]} = Client.fetch_issue_states_by_ids([work_item["id"]])
      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = LiveE2ESupport.receive_runtime_info!(issue.id)

      assert LiveE2ESupport.read_worker_result!(runtime_info, @result_file) ==
               expected_result(issue.identifier, project_id)

      work_item_snapshot = fetch_work_item!(workspace_slug, project_id, issue.id)
      comments = fetch_comments!(workspace_slug, project_id, issue.id)

      assert work_item_completed?(work_item_snapshot)
      assert comments_include_text?(comments, expected_comment_text(issue.identifier, project_id))
    after
      maybe_delete_project(workspace_slug, Process.get(project_ref))
      Process.delete(project_ref)
      LiveE2ESupport.cleanup_live_worker_setup(worker_setup)
      Workflow.set_workflow_file_path(original_workflow_path)
      LiveE2ESupport.restart_orchestrator_if_needed()
      File.rm_rf(test_root)
    end
  end

  defp write_bootstrap_workflow!(workflow_file, worker_setup, workspace_slug) do
    write_workflow_file!(workflow_file,
      tracker_kind: "plane",
      tracker_endpoint: live_plane_endpoint(),
      tracker_api_token: "$PLANE_API_KEY",
      tracker_project_slug: nil,
      tracker_workspace_slug: workspace_slug,
      tracker_project_id: nil,
      workspace_root: worker_setup.workspace_root,
      worker_ssh_hosts: worker_setup.ssh_worker_hosts,
      codex_command: worker_setup.codex_command,
      codex_approval_policy: "never",
      observability_enabled: false
    )
  end

  defp create_project!(workspace_slug, name, identifier)
       when is_binary(workspace_slug) and is_binary(name) and is_binary(identifier) do
    workspace_slug
    |> project_collection_path()
    |> plane_request!(:post, %{
      "name" => name,
      "identifier" => identifier,
      "network" => 0
    })
    |> extract_entity!("project")
  end

  defp create_work_item!(workspace_slug, project_id, state_id, title)
       when is_binary(workspace_slug) and is_binary(project_id) and is_binary(state_id) and
              is_binary(title) do
    workspace_slug
    |> work_items_collection_path(project_id)
    |> plane_request!(:post, %{
      "name" => title,
      "description_html" => "<p>#{escape_html(title)}</p>",
      "state" => state_id,
      "priority" => "medium"
    })
    |> extract_entity!("work item")
  end

  defp maybe_delete_project(_workspace_slug, nil), do: :ok

  defp maybe_delete_project(workspace_slug, project_id)
       when is_binary(workspace_slug) and is_binary(project_id) do
    case plane_request(project_path(workspace_slug, project_id), :delete) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning("Plane live e2e cleanup failed for project #{project_id}: #{inspect(reason)}")

        :ok
    end
  end

  defp list_states!(workspace_slug, project_id) when is_binary(workspace_slug) and is_binary(project_id) do
    workspace_slug
    |> states_path(project_id)
    |> plane_request!(:get)
    |> extract_results!("states")
  end

  defp fetch_work_item!(workspace_slug, project_id, work_item_id)
       when is_binary(workspace_slug) and is_binary(project_id) and is_binary(work_item_id) do
    query = %{"expand" => @expand_fields}

    workspace_slug
    |> work_item_path(project_id, work_item_id)
    |> plane_request!(:get, nil, query: query)
    |> extract_entity!("work item")
  end

  defp fetch_comments!(workspace_slug, project_id, work_item_id)
       when is_binary(workspace_slug) and is_binary(project_id) and is_binary(work_item_id) do
    query = %{"limit" => 50}

    workspace_slug
    |> comments_path(project_id, work_item_id)
    |> plane_request!(:get, nil, query: query)
    |> extract_results!("comments")
  end

  defp active_state!(states) when is_list(states) do
    Enum.find(states, &(&1["group"] == "started")) ||
      Enum.find(states, &(&1["group"] == "unstarted")) ||
      Enum.find(states, &(&1["group"] not in ["completed", "cancelled"])) ||
      flunk("expected Plane project to expose at least one non-terminal state")
  end

  defp active_state_names(states) when is_list(states) do
    states
    |> Enum.reject(&(&1["group"] in ["completed", "cancelled"]))
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> ["Todo", "In Progress"]
      names -> names
    end
  end

  defp terminal_state_names(states) when is_list(states) do
    states
    |> Enum.filter(&(&1["group"] in ["completed", "cancelled"]))
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> ["Done", "Cancelled", "Canceled"]
      names -> names
    end
  end

  defp work_item_completed?(%{"state" => %{"group" => group}}), do: group == "completed"
  defp work_item_completed?(_work_item), do: false

  defp comments_include_text?(comments, expected_text) when is_list(comments) and is_binary(expected_text) do
    normalized_expected = normalize_comment_text(expected_text)

    Enum.any?(comments, fn
      %{} = comment ->
        comment
        |> comment_text_candidates()
        |> Enum.any?(fn candidate ->
          normalized_candidate = normalize_comment_text(candidate)

          normalized_candidate == normalized_expected ||
            String.contains?(normalized_candidate, normalized_expected)
        end)

      _ ->
        false
    end)
  end

  defp comments_include_text?(_comments, _expected_text), do: false

  defp comment_text_candidates(comment) when is_map(comment) do
    [
      comment["comment_stripped"],
      strip_html(comment["comment_html"]),
      comment["comment_html"],
      comment["body"]
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp live_prompt(project_id) when is_binary(project_id) do
    """
    You are running a real Symphony end-to-end test for Plane.

    The current working directory is the workspace root.

    Step 1:
    Create a file named #{@result_file} in the current working directory.
    The file content must be exactly:

    ```text
    identifier={{ issue.identifier }}
    project_id=#{project_id}
    ```

    Use the simplest available file-editing method. Do not leave the file empty.

    Then verify it by printing the file contents:

    ```sh
    cat #{@result_file}
    ```

    Step 2:
    You must use the `plane_api` tool to query the current work item by `{{ issue.id }}` and read:
    - existing comments
    - project workflow states

    A turn that only creates the file is incomplete. Do not stop after Step 1.

    Use these exact relative REST calls:

    - `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}?expand=#{@expand_fields}`
    - `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/work-items/{{ issue.id }}/comments/`
    - `GET /workspaces/{{ tracker.workspace_slug }}/projects/{{ tracker.project_id }}/states/`

    If the exact HTML comment below is not already present, post exactly one comment on the current work item with this exact body:
    #{expected_comment_html("{{ issue.identifier }}", project_id)}

    Use this exact request body:

    ```json
    {
      "comment_html": "#{expected_comment_html("{{ issue.identifier }}", project_id)}"
    }
    ```

    Step 3:
    Use the project states response to choose a workflow state whose `group` is `completed`.
    Then move the current work item to that state with this exact request body:

    ```json
    {
      "state": "<completed-state-id>"
    }
    ```

    If Plane rejects `state`, retry once with:

    ```json
    {
      "state_id": "<completed-state-id>"
    }
    ```

    Step 4:
    Verify all outcomes with final `plane_api` reads against `{{ issue.id }}`:
    - the exact comment body is present
    - the work item state group is `completed`

    Do not ask for approval.
    Stop only after all three conditions are true:
    1. the file exists with the exact contents above
    2. the Plane comment exists with the exact body above
    3. the Plane work item is in a completed terminal state
    """
  end

  defp expected_result(issue_identifier, project_id) do
    "identifier=#{issue_identifier}\nproject_id=#{project_id}\n"
  end

  defp expected_comment_text(issue_identifier, project_id) do
    "Symphony live plane e2e comment identifier=#{issue_identifier} project_id=#{project_id}"
  end

  defp expected_comment_html(issue_identifier, project_id) do
    "<p>#{escape_html(expected_comment_text(issue_identifier, project_id))}</p>"
  end

  defp required_env!(key) when is_binary(key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("expected #{key} to be set for the live Plane e2e test")
    end
  end

  defp live_plane_endpoint do
    System.get_env("SYMPHONY_LIVE_PLANE_ENDPOINT") || "https://api.plane.so"
  end

  defp project_identifier do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string(36)
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "")
      |> String.slice(-6, 6)

    "SPE#{suffix}"
  end

  defp plane_request!(path, method, body \\ nil, opts \\ []) when is_binary(path) do
    case plane_request(path, method, body, opts) do
      {:ok, response} ->
        response

      {:error, reason} ->
        flunk("Plane API request failed for #{method} #{path}: #{inspect(reason)}")
    end
  end

  defp plane_request(path, method, body \\ nil, opts \\ []) when is_binary(path) do
    API.request(method, path, body, opts)
  end

  defp extract_entity!(%{body: %{"id" => _id} = entity}, _kind), do: entity
  defp extract_entity!(%{body: %{"project" => %{"id" => _id} = entity}}, "project"), do: entity
  defp extract_entity!(%{body: %{"work_item" => %{"id" => _id} = entity}}, "work item"), do: entity

  defp extract_entity!(response, kind) do
    flunk("expected Plane #{kind} payload, got: #{inspect(response)}")
  end

  defp extract_results!(%{body: %{"results" => results}}, _kind) when is_list(results), do: results
  defp extract_results!(%{body: results}, _kind) when is_list(results), do: results

  defp extract_results!(response, kind) do
    flunk("expected Plane #{kind} list payload, got: #{inspect(response)}")
  end

  defp normalize_comment_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<\/p>/i, " ")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp strip_html(_html), do: nil

  defp escape_html(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp project_collection_path(workspace_slug), do: "/workspaces/#{workspace_slug}/projects/"
  defp project_path(workspace_slug, project_id), do: "/workspaces/#{workspace_slug}/projects/#{project_id}"
  defp states_path(workspace_slug, project_id), do: "/workspaces/#{workspace_slug}/projects/#{project_id}/states/"
  defp work_items_collection_path(workspace_slug, project_id), do: "/workspaces/#{workspace_slug}/projects/#{project_id}/work-items/"

  defp work_item_path(workspace_slug, project_id, work_item_id) do
    "/workspaces/#{workspace_slug}/projects/#{project_id}/work-items/#{work_item_id}"
  end

  defp comments_path(workspace_slug, project_id, work_item_id) do
    "/workspaces/#{workspace_slug}/projects/#{project_id}/work-items/#{work_item_id}/comments/"
  end
end
