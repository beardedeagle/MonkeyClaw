defmodule MonkeyClaw.Experiments.IterationTest do
  use MonkeyClaw.DataCase, async: true

  alias MonkeyClaw.Experiments.Iteration

  import MonkeyClaw.Factory

  describe "create_changeset/2" do
    test "valid with required fields" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{sequence: 1, status: :accepted})

      assert changeset.valid?
    end

    test "requires sequence" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{status: :accepted})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).sequence
    end

    test "requires status" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{sequence: 1})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).status
    end

    test "validates sequence positive" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{sequence: 0, status: :accepted})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).sequence
    end

    test "validates status inclusion" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{sequence: 1, status: :invalid})

      refute changeset.valid?
    end

    test "accepts eval_result and state_snapshot" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{
          sequence: 1,
          status: :accepted,
          eval_result: %{score: 0.85},
          state_snapshot: %{__v__: 1, best_score: 0.85},
          duration_ms: 3200
        })

      assert changeset.valid?
    end

    test "normalizes nil map fields to empty maps" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{
          sequence: 1,
          status: :accepted,
          eval_result: nil,
          state_snapshot: nil,
          metadata: nil
        })

      assert changeset.valid?
      # Schema defaults are %{} — normalization removes nil changes,
      # so the final field value is %{} from the default (no change entry).
      assert Ecto.Changeset.get_field(changeset, :eval_result) == %{}
      assert Ecto.Changeset.get_field(changeset, :state_snapshot) == %{}
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end

    test "validates duration_ms non-negative" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      changeset =
        experiment
        |> Ecto.build_assoc(:iterations)
        |> Iteration.create_changeset(%{sequence: 1, status: :accepted, duration_ms: -1})

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).duration_ms
    end

    test "all valid statuses" do
      for status <- Iteration.statuses() do
        workspace = insert_workspace!()
        experiment = insert_experiment!(workspace)

        changeset =
          experiment
          |> Ecto.build_assoc(:iterations)
          |> Iteration.create_changeset(%{sequence: 1, status: status})

        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end
  end
end
