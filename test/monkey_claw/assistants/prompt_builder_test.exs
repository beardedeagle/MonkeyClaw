defmodule MonkeyClaw.Assistants.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Assistants.{Assistant, PromptBuilder}

  doctest MonkeyClaw.Assistants.PromptBuilder

  describe "build_system_prompt/1" do
    test "composes all three layers with double newlines" do
      assistant = %Assistant{
        system_prompt: "You are MonkeyClaw.",
        persona_prompt: "Be concise and precise.",
        context_prompt: "Working on the Elixir project."
      }

      result = PromptBuilder.build_system_prompt(assistant)

      assert result ==
               "You are MonkeyClaw.\n\nBe concise and precise.\n\nWorking on the Elixir project."
    end

    test "composes system_prompt and persona_prompt" do
      assistant = %Assistant{
        system_prompt: "You are MonkeyClaw.",
        persona_prompt: "Be concise.",
        context_prompt: nil
      }

      result = PromptBuilder.build_system_prompt(assistant)
      assert result == "You are MonkeyClaw.\n\nBe concise."
    end

    test "composes system_prompt and context_prompt" do
      assistant = %Assistant{
        system_prompt: "You are MonkeyClaw.",
        persona_prompt: nil,
        context_prompt: "Working on Elixir."
      }

      result = PromptBuilder.build_system_prompt(assistant)
      assert result == "You are MonkeyClaw.\n\nWorking on Elixir."
    end

    test "composes persona_prompt and context_prompt" do
      assistant = %Assistant{
        system_prompt: nil,
        persona_prompt: "Be helpful.",
        context_prompt: "Elixir project."
      }

      result = PromptBuilder.build_system_prompt(assistant)
      assert result == "Be helpful.\n\nElixir project."
    end

    test "returns only system_prompt when others are nil" do
      assistant = %Assistant{
        system_prompt: "You are MonkeyClaw.",
        persona_prompt: nil,
        context_prompt: nil
      }

      assert PromptBuilder.build_system_prompt(assistant) == "You are MonkeyClaw."
    end

    test "returns only persona_prompt when others are nil" do
      assistant = %Assistant{
        system_prompt: nil,
        persona_prompt: "Be helpful.",
        context_prompt: nil
      }

      assert PromptBuilder.build_system_prompt(assistant) == "Be helpful."
    end

    test "returns only context_prompt when others are nil" do
      assistant = %Assistant{
        system_prompt: nil,
        persona_prompt: nil,
        context_prompt: "Elixir project."
      }

      assert PromptBuilder.build_system_prompt(assistant) == "Elixir project."
    end

    test "returns nil when all layers are nil" do
      assistant = %Assistant{
        system_prompt: nil,
        persona_prompt: nil,
        context_prompt: nil
      }

      assert PromptBuilder.build_system_prompt(assistant) == nil
    end

    test "preserves layer content exactly" do
      assistant = %Assistant{
        system_prompt: "  leading spaces  ",
        persona_prompt: "line1\nline2",
        context_prompt: "trailing context"
      }

      result = PromptBuilder.build_system_prompt(assistant)
      assert result == "  leading spaces  \n\nline1\nline2\n\ntrailing context"
    end

    test "filters empty string layers" do
      assistant = %Assistant{
        system_prompt: "Identity.",
        persona_prompt: "",
        context_prompt: "Context."
      }

      result = PromptBuilder.build_system_prompt(assistant)
      assert result == "Identity.\n\nContext."
    end

    test "returns nil when all layers are empty strings" do
      assistant = %Assistant{
        system_prompt: "",
        persona_prompt: "",
        context_prompt: ""
      }

      assert PromptBuilder.build_system_prompt(assistant) == nil
    end

    test "filters mix of nil and empty string layers" do
      assistant = %Assistant{
        system_prompt: nil,
        persona_prompt: "",
        context_prompt: "Only this."
      }

      assert PromptBuilder.build_system_prompt(assistant) == "Only this."
    end

    test "rejects non-Assistant struct" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PromptBuilder, :build_system_prompt, [%{system_prompt: "test"}])
      end
    end

    test "rejects plain map" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PromptBuilder, :build_system_prompt, [
          %{system_prompt: "a", persona_prompt: "b", context_prompt: "c"}
        ])
      end
    end
  end
end
