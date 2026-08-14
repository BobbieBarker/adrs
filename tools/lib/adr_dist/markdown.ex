defmodule AdrDist.Markdown.Section do
  @moduledoc false

  @enforce_keys [
    :level,
    :heading,
    :title,
    :path,
    :body,
    :display_text,
    :start_line,
    :end_line
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          level: 1..6,
          heading: String.t(),
          title: String.t(),
          path: [String.t()],
          body: String.t(),
          display_text: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }
end

defmodule AdrDist.Markdown.Example do
  @moduledoc false

  @enforce_keys [:kind, :label, :body, :display_text, :start_line, :end_line]
  defstruct @enforce_keys

  @type kind :: :correct | :wrong
  @type t :: %__MODULE__{
          kind: kind(),
          label: String.t(),
          body: String.t(),
          display_text: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }
end

defmodule AdrDist.Markdown.Rule do
  @moduledoc false

  alias AdrDist.Markdown.Example

  @enforce_keys [
    :number,
    :title,
    :heading,
    :path,
    :body,
    :display_text,
    :statement,
    :why,
    :correct,
    :wrong,
    :start_line,
    :end_line
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          number: pos_integer(),
          title: String.t(),
          heading: String.t(),
          path: [String.t()],
          body: String.t(),
          display_text: String.t(),
          statement: String.t(),
          why: String.t(),
          correct: Example.t(),
          wrong: Example.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }
end

defmodule AdrDist.Markdown.Document do
  @moduledoc false

  alias AdrDist.Markdown.{Rule, Section}

  @enforce_keys [:title, :context, :decision, :consequences, :rules, :supporting]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t(),
          context: Section.t(),
          decision: Section.t(),
          consequences: Section.t(),
          rules: [Rule.t()],
          supporting: [Section.t()]
        }
end

defmodule AdrDist.Markdown do
  @moduledoc """
  Parses the constrained ADR Markdown format without treating headings or labels
  inside fenced code blocks as document structure.
  """

  alias AdrDist.Markdown.{Document, Example, Rule, Section}

  @rule_heading ~r/^Rule\s+(\d+):\s+(.+)$/u
  @example_label ~r/^(\*\*(Correct|Wrong)(?:\s+\(.+\))?:\*\*)(.*)$/u
  @why_label ~r/^\*\*Why:\*\*(.*)$/u

  @type parse_error :: {:invalid_markdown, pos_integer(), String.t()}

  @spec parse(String.t()) :: {:ok, Document.t()} | {:error, parse_error()}
  def parse(body) when is_binary(body) do
    parse(body, 0)
  end

  @spec parse(String.t(), non_neg_integer()) :: {:ok, Document.t()} | {:error, parse_error()}
  def parse(body, line_offset)
      when is_binary(body) and is_integer(line_offset) and line_offset >= 0 do
    case sections(body, line_offset) do
      {:ok, parsed_sections} -> build_document(parsed_sections)
      {:error, _reason} = error -> error
    end
  end

  @spec section_content(Section.t()) :: String.t()
  def section_content(%Section{} = section) do
    section.display_text
  end

  @spec rule_content(Rule.t()) :: String.t()
  def rule_content(%Rule{} = rule) do
    [rule.heading, rule.statement, "**Why:** " <> rule.why]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec example_content(Example.t()) :: String.t()
  def example_content(%Example{} = example) do
    example.display_text
  end

  defp sections(body, line_offset) do
    lines = String.split(body, "\n", trim: false)

    initial = %{
      current: nil,
      fence: nil,
      sections: [],
      stack: []
    }

    lines
    |> Enum.with_index(line_offset + 1)
    |> Enum.reduce_while({:ok, initial}, &scan_line/2)
    |> finish_sections(length(lines) + line_offset)
  end

  defp scan_line({_line, _line_number}, {:error, _reason} = error), do: {:halt, error}

  defp scan_line({line, line_number}, {:ok, state}) do
    case fence_transition(line, state.fence) do
      {:opened, fence} ->
        {character, length} = fence
        opened_fence = {character, length, line_number}
        {:cont, {:ok, append_line(%{state | fence: opened_fence}, line)}}

      :closed ->
        {:cont, {:ok, append_line(%{state | fence: nil}, line)}}

      :inside ->
        {:cont, {:ok, append_line(state, line)}}

      :outside ->
        case heading(line) do
          {:ok, level, title} ->
            cond do
              invalid_rule_heading_level?(level, title) ->
                {:halt,
                 {:error, {:invalid_markdown, line_number, "Rule headings must use H3 or H4"}}}

              nested_rule_heading?(state.current, level) ->
                {:cont, {:ok, append_line(state, line)}}

              true ->
                {:cont, {:ok, open_section(state, level, title, line, line_number)}}
            end

          :no_heading ->
            {:cont, {:ok, append_line(state, line)}}
        end
    end
  end

  defp finish_sections({:error, _reason} = error, _last_line), do: error

  defp finish_sections({:ok, %{fence: {_character, _length, opening_line}}}, _last_line) do
    {:error, {:invalid_markdown, opening_line, "unclosed fenced code block"}}
  end

  defp finish_sections({:ok, state}, last_line) do
    sections =
      state
      |> close_current(last_line)
      |> Map.fetch!(:sections)
      |> Enum.reverse()

    {:ok, sections}
  end

  defp fence_transition(line, nil) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})/, line) do
      [_, marker] -> {:opened, {String.first(marker), String.length(marker)}}
      nil -> :outside
    end
  end

  defp fence_transition(line, {character, minimum_length, _opening_line}) do
    escaped = Regex.escape(character)

    if Regex.match?(~r/^\s*#{escaped}{#{minimum_length},}\s*$/, line),
      do: :closed,
      else: :inside
  end

  defp heading(line) do
    case Regex.run(~r/^(\#{1,6})\s+(.+?)\s*$/u, line) do
      [_, hashes, title] -> {:ok, String.length(hashes), title}
      nil -> :no_heading
    end
  end

  defp nested_rule_heading?(nil, _level), do: false

  defp nested_rule_heading?(%{level: current_level, title: title}, level) do
    level > current_level and Regex.match?(@rule_heading, title)
  end

  defp invalid_rule_heading_level?(level, title) do
    Regex.match?(@rule_heading, title) and level not in 3..4
  end

  defp open_section(state, level, title, heading_line, line_number) do
    state = close_current(state, line_number - 1)
    stack = Enum.reject(state.stack, fn {parent_level, _title} -> parent_level >= level end)
    path = Enum.map(stack, &elem(&1, 1)) ++ [title]

    current = %{
      level: level,
      heading: heading_line,
      title: title,
      path: path,
      body_lines: [],
      start_line: line_number
    }

    %{state | current: current, stack: stack ++ [{level, title}]}
  end

  defp append_line(%{current: nil} = state, _line), do: state

  defp append_line(%{current: current} = state, line) do
    %{state | current: %{current | body_lines: [line | current.body_lines]}}
  end

  defp close_current(%{current: nil} = state, _end_line), do: state

  defp close_current(%{current: current} = state, end_line) do
    raw_body = current.body_lines |> Enum.reverse() |> Enum.join("\n")

    section = %Section{
      level: current.level,
      heading: current.heading,
      title: current.title,
      path: current.path,
      body: raw_body,
      display_text: String.trim(current.heading <> "\n" <> raw_body),
      start_line: current.start_line,
      end_line: max(current.start_line, end_line)
    }

    %{state | current: nil, sections: [section | state.sections]}
  end

  defp build_document(sections) do
    titles = Enum.filter(sections, &(&1.level == 1))
    contexts = Enum.filter(sections, &(&1.level == 2 and &1.title == "Context"))
    decisions = Enum.filter(sections, &(&1.level == 2 and &1.title == "Decision"))

    consequences_sections =
      Enum.filter(sections, &(&1.level == 2 and &1.title == "Consequences"))

    case {titles, contexts, decisions, consequences_sections} do
      {[title], [context], [decision], [consequences]} ->
        if title.start_line < context.start_line and context.start_line < decision.start_line and
             decision.start_line < consequences.start_line do
          build_document_sections(title, context, decision, consequences, sections)
        else
          {:error,
           {:invalid_markdown, out_of_order_line(title, context, decision, consequences),
            "H1, Context, Decision, and Consequences sections must appear in that order"}}
        end

      _ ->
        {:error,
         {:invalid_markdown, duplicate_or_missing_section_line(sections),
          "expected exactly one H1 title and one Context, Decision, and Consequences H2 section"}}
    end
  end

  defp build_document_sections(title, context, decision, consequences, sections) do
    rule_sections = Enum.filter(sections, &Regex.match?(@rule_heading, &1.title))

    case validate_rule_placement(rule_sections, decision, consequences) do
      :ok ->
        case parse_rules(rule_sections, decision.start_line) do
          {:ok, rules} ->
            supporting = supporting_sections(sections, decision, consequences)

            {:ok,
             %Document{
               title: title.title,
               context: context,
               decision: decision,
               consequences: consequences,
               rules: rules,
               supporting: supporting
             }}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_rule_placement(rule_sections, decision, consequences) do
    misplaced =
      Enum.find(rule_sections, fn section ->
        not (section.start_line > decision.start_line and
               section.start_line < consequences.start_line and
               valid_rule_parent?(section, decision))
      end)

    case misplaced do
      nil ->
        :ok

      section ->
        message =
          if section.start_line <= decision.start_line or
               section.start_line >= consequences.start_line do
            "Rule headings must appear within the Decision section"
          else
            "H3 Rules must be direct Decision children; H4 Rules must be under Universal rules or Situational rules"
          end

        {:error,
         {:invalid_markdown, section.start_line, message}}
    end
  end

  defp valid_rule_parent?(%Section{level: 3} = section, decision) do
    section.path == decision.path ++ [section.title]
  end

  defp valid_rule_parent?(%Section{level: 4} = section, decision) do
    case section.path do
      path when length(path) == length(decision.path) + 2 ->
        parent = Enum.at(path, -2)
        List.starts_with?(path, decision.path) and parent in ["Universal rules", "Situational rules"]

      _path ->
        false
    end
  end

  defp valid_rule_parent?(_section, _decision), do: false

  defp parse_rules(rule_sections, fallback_line) do
    rule_sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, rules} ->
      case parse_rule(section) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rules} -> validate_rule_numbers(Enum.reverse(rules), fallback_line)
      {:error, _reason} = error -> error
    end
  end

  defp parse_rule(%Section{} = section) do
    [_, number, title] = Regex.run(@rule_heading, section.title)

    case split_rule_body(section.body, section.start_line) do
      {:ok, parts} ->
        {:ok,
         %Rule{
           number: String.to_integer(number),
           title: title,
           heading: section.heading,
           path: section.path,
           body: section.body,
           display_text: section.display_text,
           statement: parts.statement,
           why: parts.why,
           correct: %Example{
             kind: :correct,
             label: parts.correct_label,
             body: parts.correct,
             display_text: parts.correct_display,
             start_line: section.start_line + parts.correct_start,
             end_line: section.start_line + parts.correct_end
           },
           wrong: %Example{
             kind: :wrong,
             label: parts.wrong_label,
             body: parts.wrong,
             display_text: parts.wrong_display,
             start_line: section.start_line + parts.wrong_start,
             end_line: section.start_line + parts.wrong_end
           },
           start_line: section.start_line,
           end_line: section.end_line
         }}

      {:error, line, reason} ->
        {:error, {:invalid_markdown, line, "#{section.title}: #{reason}"}}
    end
  end

  defp split_rule_body(body, rule_start_line) do
    initial = %{
      current: :statement,
      fence: nil,
      parts: %{statement: [], correct: [], wrong: [], why: []},
      correct_label: nil,
      wrong_label: nil,
      marker_lines: %{},
      seen: [],
      line_offset: rule_start_line,
      rule_start_line: rule_start_line
    }

    lines = String.split(body, "\n", trim: false)

    result =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, initial}, &scan_rule_line/2)
      |> finish_rule_parts()

    case result do
      {:ok, parts} ->
        {:ok,
         parts
         |> Map.put(
           :correct_display,
           source_region(lines, parts.correct_start, parts.correct_end)
         )
         |> Map.put(:wrong_display, source_region(lines, parts.wrong_start, parts.wrong_end))}

      {:error, _line, _reason} = error ->
        error
    end
  end

  defp scan_rule_line(_line_with_number, {:error, _line, _reason} = error), do: {:halt, error}

  defp scan_rule_line({line, relative_line}, {:ok, state}) do
    case fence_transition(line, state.fence) do
      {:opened, fence} ->
        opening_line = state.line_offset + relative_line
        {character, length} = fence
        opened_fence = {character, length, opening_line}
        {:cont, {:ok, append_rule_line(%{state | fence: opened_fence}, line)}}

      :closed ->
        {:cont, {:ok, append_rule_line(%{state | fence: nil}, line)}}

      :inside ->
        {:cont, {:ok, append_rule_line(state, line)}}

      :outside ->
        scan_rule_marker(line, relative_line, state)
    end
  end

  defp scan_rule_marker(line, relative_line, state) do
    cond do
      Regex.match?(@example_label, line) ->
        [_, label, label_kind, inline_example] = Regex.run(@example_label, line)
        kind = if label_kind == "Correct", do: :correct, else: :wrong

        case transition_rule_part(state, kind, label, relative_line) do
          {:cont, {:ok, example_state}} ->
            {:cont, {:ok, append_rule_line(example_state, String.trim_leading(inline_example))}}

          transition ->
            transition
        end

      Regex.match?(@why_label, line) ->
        [_, inline_why] = Regex.run(@why_label, line)

        case transition_rule_part(state, :why, nil, relative_line) do
          {:cont, {:ok, why_state}} ->
            {:cont, {:ok, append_rule_line(why_state, String.trim_leading(inline_why))}}

          transition ->
            transition
        end

      true ->
        {:cont, {:ok, append_rule_line(state, line)}}
    end
  end

  defp transition_rule_part(state, kind, label, relative_line) do
    expected = %{correct: :statement, wrong: :correct, why: :wrong}

    cond do
      kind in state.seen ->
        {:halt, {:error, state.line_offset + relative_line, "duplicate #{kind} section"}}

      state.current != Map.fetch!(expected, kind) ->
        {:halt, {:error, state.line_offset + relative_line, "#{kind} section is out of order"}}

      true ->
        labels =
          case kind do
            :correct -> %{correct_label: label}
            :wrong -> %{wrong_label: label}
            :why -> %{}
          end

        next_state =
          state
          |> Map.merge(labels)
          |> Map.put(:current, kind)
          |> Map.update!(:seen, &[kind | &1])
          |> put_in([:marker_lines, kind], relative_line)

        {:cont, {:ok, next_state}}
    end
  end

  defp append_rule_line(state, line) do
    update_in(state, [:parts, state.current], &[line | &1])
  end

  defp finish_rule_parts({:error, _line, _reason} = error), do: error

  defp finish_rule_parts({:ok, %{fence: {_character, _length, opening_line}}}),
    do: {:error, opening_line, "unclosed fenced code block inside rule"}

  defp finish_rule_parts({:ok, state}) do
    if Enum.sort(state.seen) == [:correct, :why, :wrong] do
      parts =
        state.parts
        |> Map.new(fn {kind, lines} ->
          {kind, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
        end)
        |> Map.put(:correct_label, state.correct_label)
        |> Map.put(:wrong_label, state.wrong_label)
        |> Map.put(:correct_start, Map.fetch!(state.marker_lines, :correct))
        |> Map.put(:correct_end, Map.fetch!(state.marker_lines, :wrong) - 1)
        |> Map.put(:wrong_start, Map.fetch!(state.marker_lines, :wrong))
        |> Map.put(:wrong_end, Map.fetch!(state.marker_lines, :why) - 1)

      {:ok, parts}
    else
      {:error, state.rule_start_line, "expected exactly one Correct, Wrong, and Why section"}
    end
  end

  defp validate_rule_numbers(rules, fallback_line) do
    numbers = Enum.map(rules, & &1.number)

    cond do
      numbers == [] ->
        {:error, {:invalid_markdown, fallback_line, "ADR contains no numbered rules"}}

      length(numbers) != length(Enum.uniq(numbers)) ->
        {:error,
         {:invalid_markdown, duplicate_rule_line(rules), "ADR contains duplicate rule numbers"}}

      numbers != Enum.to_list(1..length(numbers)) ->
        {:error,
         {:invalid_markdown, noncontiguous_rule_line(rules),
          "ADR rule numbers must be contiguous starting at 1"}}

      true ->
        {:ok, rules}
    end
  end

  defp duplicate_or_missing_section_line(sections) do
    structural =
      Enum.filter(sections, fn section ->
        section.level == 1 or
          (section.level == 2 and section.title in ["Context", "Decision", "Consequences"])
      end)

    duplicate_line =
      structural
      |> Enum.group_by(fn section -> {section.level, section.title} end)
      |> Enum.flat_map(fn {_identity, matches} -> Enum.drop(matches, 1) end)
      |> Enum.map(& &1.start_line)
      |> Enum.min(fn -> nil end)

    duplicate_line || structural |> List.first() |> section_line()
  end

  defp out_of_order_line(title, context, decision, consequences) do
    [{title, context}, {context, decision}, {decision, consequences}]
    |> Enum.find(fn {left, right} -> left.start_line >= right.start_line end)
    |> case do
      {_left, right} -> right.start_line
      nil -> decision.start_line
    end
  end

  defp section_line(nil), do: 1
  defp section_line(%Section{} = section), do: section.start_line

  defp duplicate_rule_line(rules) do
    {_seen, duplicate} =
      Enum.reduce_while(rules, {MapSet.new(), nil}, fn rule, {seen, _duplicate} ->
        if MapSet.member?(seen, rule.number),
          do: {:halt, {seen, rule.start_line}},
          else: {:cont, {MapSet.put(seen, rule.number), nil}}
      end)

    duplicate || hd(rules).start_line
  end

  defp noncontiguous_rule_line(rules) do
    rules
    |> Enum.with_index(1)
    |> Enum.find_value(hd(rules).start_line, fn {rule, expected} ->
      if rule.number != expected, do: rule.start_line
    end)
  end

  defp source_region(lines, first, last) do
    lines
    |> Enum.slice((first - 1)..(last - 1))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp supporting_sections(sections, decision, consequences) do
    Enum.filter(sections, fn section ->
      section.start_line > decision.start_line and
        section.start_line < consequences.start_line and
        section.level in 3..4 and
        not Regex.match?(@rule_heading, section.title) and
        section.title not in ["Universal rules", "Situational rules"]
    end)
  end
end
