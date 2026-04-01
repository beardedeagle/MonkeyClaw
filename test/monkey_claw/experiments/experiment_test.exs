defmodule MonkeyClaw.Experiments.ExperimentTest do
  use MonkeyClaw.DataCase, async: true

  alias MonkeyClaw.Experiments.Experiment

  import MonkeyClaw.Factory

  describe "create_changeset/2" do
    test "valid with required fields" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Optimize parser",
          type: :code,
          max_iterations: 5
        })

      assert changeset.valid?
    end

    test "requires title" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{type: :code, max_iterations: 5})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "requires type" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{title: "Test", max_iterations: 5})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).type
    end

    test "requires max_iterations" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{title: "Test", type: :code})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).max_iterations
    end

    test "validates title length" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: String.duplicate("a", 201),
          type: :code,
          max_iterations: 5
        })

      refute changeset.valid?
      assert "should be at most 200 character(s)" in errors_on(changeset).title
    end

    test "validates type inclusion" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Test",
          type: :invalid,
          max_iterations: 5
        })

      refute changeset.valid?
    end

    test "validates max_iterations range" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Test",
          type: :code,
          max_iterations: 0
        })

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).max_iterations

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Test",
          type: :code,
          max_iterations: 101
        })

      refute changeset.valid?
    end

    test "validates time_budget_ms range" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Test",
          type: :code,
          max_iterations: 5,
          time_budget_ms: -1
        })

      refute changeset.valid?
    end

    test "accepts config map" do
      workspace = insert_workspace!()

      changeset =
        workspace
        |> Ecto.build_assoc(:experiments)
        |> Experiment.create_changeset(%{
          title: "Test",
          type: :code,
          max_iterations: 5,
          config: %{"scoped_files" => ["lib/foo.ex"]}
        })

      assert changeset.valid?
    end

    test "defaults to :created status" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)
      assert experiment.status == :created
    end

    test "defaults config to empty map" do
      workspace = insert_workspace!()

      experiment =
        insert_experiment!(workspace, %{config: %{}})

      assert experiment.config == %{}
    end
  end

  describe "update_changeset/2" do
    test "updates status" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset = Experiment.update_changeset(experiment, %{status: :running})
      assert changeset.valid?
    end

    test "updates state (opaque map)" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        Experiment.update_changeset(experiment, %{
          state: %{"__v__" => 1, "best_score" => 0.85}
        })

      assert changeset.valid?
    end

    test "validates iteration_count non-negative" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset = Experiment.update_changeset(experiment, %{iteration_count: -1})
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).iteration_count
    end
  end

  describe "terminal?/1" do
    test "returns true for terminal statuses" do
      for status <- [:accepted, :rejected, :cancelled, :halted] do
        assert Experiment.terminal?(status)
      end
    end

    test "returns false for non-terminal statuses" do
      for status <- [:created, :running, :evaluating, :awaiting_human] do
        refute Experiment.terminal?(status)
      end
    end
  end

  describe "experiment_types/0" do
    test "returns all valid types" do
      assert [:code, :research, :prompt] = Experiment.experiment_types()
    end
  end
end
