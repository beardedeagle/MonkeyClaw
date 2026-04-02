defmodule MonkeyClaw.UserModeling.ObserverTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.UserModeling
  alias MonkeyClaw.UserModeling.Observer

  setup do
    # Observer is disabled in test.exs (:start_observer false).
    # Start a test-controlled instance with a long flush interval
    # so the periodic timer doesn't fire during tests.
    Application.put_env(:monkey_claw, :observer_flush_interval_ms, 999_999_999)
    start_supervised!(Observer)
    on_exit(fn -> Application.delete_env(:monkey_claw, :observer_flush_interval_ms) end)
    :ok
  end

  describe "buffer_size/0" do
    test "starts at zero" do
      assert Observer.buffer_size() == 0
    end

    test "increments after each observe call" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "first prompt"})
      Observer.flush()
      # Re-observe after flush to test clean state
      assert Observer.buffer_size() == 0

      Observer.observe(workspace.id, %{prompt: "second prompt"})
      assert Observer.buffer_size() == 1
    end

    test "accumulates multiple observations for same workspace" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "prompt one"})
      Observer.observe(workspace.id, %{prompt: "prompt two"})
      Observer.observe(workspace.id, %{prompt: "prompt three"})

      assert Observer.buffer_size() == 3
    end

    test "accumulates observations across multiple workspaces" do
      workspace_a = insert_workspace!()
      workspace_b = insert_workspace!()

      Observer.observe(workspace_a.id, %{prompt: "workspace a prompt"})
      Observer.observe(workspace_b.id, %{prompt: "workspace b prompt"})

      assert Observer.buffer_size() == 2
    end
  end

  describe "observe/2" do
    test "observe is non-blocking and buffers the observation" do
      workspace = insert_workspace!()

      :ok = Observer.observe(workspace.id, %{prompt: "async observation"})

      assert Observer.buffer_size() == 1
    end
  end

  describe "flush/0" do
    test "writes observations to the database" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "deploy elixir release"})
      :ok = Observer.flush()

      {:ok, profile} = UserModeling.get_profile(workspace.id)
      assert map_size(profile.observed_topics) > 0
    end

    test "clears the buffer after flush" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "some user prompt"})
      assert Observer.buffer_size() == 1

      :ok = Observer.flush()

      assert Observer.buffer_size() == 0
    end

    test "flush with empty buffer is a no-op" do
      assert Observer.buffer_size() == 0
      assert :ok = Observer.flush()
      assert Observer.buffer_size() == 0
    end

    test "flush does not leave a profile when workspace does not exist" do
      # generate a random UUID that has no workspace record
      fake_id = Ecto.UUID.generate()

      Observer.observe(fake_id, %{prompt: "orphan observation"})
      :ok = Observer.flush()

      assert {:error, :not_found} = UserModeling.get_profile(fake_id)
    end
  end

  describe "merge behavior" do
    test "multiple observations for same workspace are merged on flush" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "elixir phoenix deployment"})
      Observer.observe(workspace.id, %{prompt: "otp supervision trees"})
      :ok = Observer.flush()

      {:ok, profile} = UserModeling.get_profile(workspace.id)
      # Both prompts contribute topics — at least one topic from each should appear
      assert map_size(profile.observed_topics) > 0
      # "elixir" and "phoenix" from first prompt, "supervision" and "trees" from second
      all_topics = Map.keys(profile.observed_topics)
      assert Enum.any?(all_topics, &String.contains?(&1, "elixir"))
    end

    test "subsequent flushes accumulate topics into existing profile" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "elixir otp processes"})
      :ok = Observer.flush()

      {:ok, profile_after_first} = UserModeling.get_profile(workspace.id)
      first_topic_count = map_size(profile_after_first.observed_topics)

      Observer.observe(workspace.id, %{prompt: "phoenix liveview channels websocket"})
      :ok = Observer.flush()

      {:ok, profile_after_second} = UserModeling.get_profile(workspace.id)
      assert map_size(profile_after_second.observed_topics) >= first_topic_count
    end
  end

  describe "terminate/2" do
    test "flushes buffer to database on stop" do
      workspace = insert_workspace!()

      Observer.observe(workspace.id, %{prompt: "ecto sqlite database queries"})
      assert Observer.buffer_size() == 1

      pid = Process.whereis(Observer)
      ref = Process.monitor(pid)
      GenServer.stop(pid)

      # Wait for the process to fully stop before querying DB
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> flunk("Observer did not stop within 1 second")
      end

      {:ok, profile} = UserModeling.get_profile(workspace.id)
      assert map_size(profile.observed_topics) > 0
    end
  end
end
