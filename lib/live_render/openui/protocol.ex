defmodule LiveRender.OpenUI.Protocol do
  @moduledoc """
  The OpenUI message protocol (prompt.md, section 7): marker lines a host stores a response with.

      ]]>openui:content?library=support%401.2.0
      root = Card([title])
      ]]>openui:context
      {"formState":{"note":"rush"}}
      ]]>openui:end

  The model never writes or sees these lines. `parse/2` reads a stored message, `build/1` writes
  one, `for_model/1` gives the text that may go into a model request, and `user_turn/3` writes the
  reference format of a user turn produced by `@ToAssistant`.
  """

  @prefix "]]>openui:"

  defmodule Message do
    @moduledoc "A parsed stored message."
    defstruct content: "", context: nil, attributes: %{}, end: false

    @type t :: %__MODULE__{
            content: String.t(),
            context: term(),
            attributes: %{String.t() => String.t()},
            end: boolean()
          }
  end

  @doc """
  Splits a stored message into its content, context, attributes and end flag.

  The last `content` section wins. Text before the first marker is the content only when there is
  no `content` marker. A `context` section or `end` line before the winning content belongs to an
  earlier attempt and is ignored. Unknown kinds are stripped with their bodies.

  With `streaming: true`, a last line that is (or may become) a marker is held back.
  """
  @spec parse(String.t(), keyword()) :: Message.t()
  def parse(raw, opts \\ []) do
    streaming = Keyword.get(opts, :streaming, false)
    text = split_inline_content_markers(raw)
    text = if streaming, do: hold_back_inline_cut(text), else: text
    lines = String.split(text, "\n")
    last = List.last(lines)

    held =
      streaming and last != "" and
        (String.starts_with?(last, @prefix) or String.starts_with?(@prefix, last))

    lines = if held, do: Enum.drop(lines, -1), else: lines

    {sections, end_at} = read_sections(lines)
    kinds = Enum.map(sections, & &1.kind)
    win = max(0, last_index(kinds, "content"))
    ctx = last_index(kinds, "context")
    winner = Enum.at(sections, win)

    context =
      if ctx > win do
        body = sections |> Enum.at(ctx) |> body()

        case Jason.decode(body) do
          {:ok, value} -> value
          {:error, _} -> body
        end
      end

    %Message{
      content: body(winner),
      context: context,
      attributes: winner.attributes,
      end: end_at >= win
    }
  end

  @doc "The program text of a message: the winning content section, or the text itself."
  @spec content(String.t(), keyword()) :: String.t()
  def content(text, opts \\ []) do
    if String.contains?(text, @prefix) or (Keyword.get(opts, :streaming) && partial_prefix?(text)),
      do: parse(text, opts).content,
      else: text
  end

  defp partial_prefix?(text) do
    last = text |> String.split("\n") |> List.last()
    last != "" and String.starts_with?(@prefix, last)
  end

  @doc """
  Writes a stored message. `context` is written as is when it is a string, else as JSON, and is
  left out when nil. `attributes` are encoded like `URLSearchParams`.
  """
  @spec build(keyword() | map()) :: String.t()
  def build(input) do
    input = Map.new(input)
    content = Map.get(input, :content, "")
    attributes = Map.get(input, :attributes, %{})

    query =
      attributes
      |> Enum.map_join("&", fn {k, v} -> encode(to_string(k)) <> "=" <> encode(to_string(v)) end)

    out = @prefix <> "content" <> if(query == "", do: "", else: "?" <> query) <> "\n" <> content

    out =
      case Map.get(input, :context) do
        nil -> out
        ctx when is_binary(ctx) -> out <> "\n" <> @prefix <> "context\n" <> ctx
        ctx -> out <> "\n" <> @prefix <> "context\n" <> Jason.encode!(ctx)
      end

    if Map.get(input, :end, false), do: out <> "\n" <> @prefix <> "end", else: out
  end

  @doc """
  The `library=<id>@<version>` attribute for a library, or an empty map when it has no id.
  """
  @spec library_attributes(LiveRender.OpenUI.Library.t()) :: %{String.t() => String.t()}
  def library_attributes(%{id: nil}), do: %{}
  def library_attributes(%{id: id, version: nil}), do: %{"library" => id}
  def library_attributes(%{id: id, version: v}), do: %{"library" => "#{id}@#{v}"}

  @doc """
  The text of a stored assistant message as the model may see it: the program text only, with
  every marker line and the context section removed (prompt.md, section 7.5).
  """
  @spec for_model(String.t()) :: String.t()
  def for_model(stored), do: parse(stored).content

  @doc """
  Writes a user turn in the reference format (prompt.md, section 6.3):

      ]]>openui:content
      <message>
      ]]>openui:context
      ["User clicked: <message>", <formState>, <context>]

  The context element is added only when the action passed one.
  """
  @spec user_turn(String.t(), map() | nil, term()) :: String.t()
  def user_turn(message, form_state, context \\ :none) do
    ctx = ["User clicked: " <> message, form_state || %{}]
    ctx = if context == :none, do: ctx, else: ctx ++ [context]
    build(content: message, context: ctx)
  end

  @doc """
  The single user message the model receives for a stored user turn: the message text, a
  newline, then `context and form values = <JSON>`. Markers are removed.
  """
  @spec user_turn_for_model(String.t()) :: String.t()
  def user_turn_for_model(stored) do
    %Message{content: content, context: context} = parse(stored)

    case context do
      nil -> content
      ctx when is_binary(ctx) -> content <> "\ncontext and form values = " <> ctx
      ctx -> content <> "\ncontext and form values = " <> Jason.encode!(ctx)
    end
  end

  # ── Reading ──────────────────────────────────────────────────────────────

  # A `content` marker in the middle of a line starts a new line, so a regenerated response written
  # right after cut-off text still wins.
  defp split_inline_content_markers(text) do
    Regex.replace(~r/([^\n])(?=\]\]>openui:content(?:\?|\r?\n|$))/, text, "\\1\n")
  end

  # While streaming, hold back a mid-line `]]>openui:con` that may become a content marker.
  defp hold_back_inline_cut(text) do
    case Regex.run(~r/[^\n](\]\]>[a-z:]*)$/, text, return: :index) do
      [{start, _len}, {cut_start, cut_len}] ->
        cut = binary_part(text, cut_start, cut_len)

        if String.starts_with?(@prefix <> "content", cut),
          do: binary_part(text, 0, start + 1),
          else: text

      _ ->
        text
    end
  end

  defp read_sections(lines) do
    initial = {[%{kind: nil, attributes: %{}, lines: []}], -1}
    count = length(lines)

    lines
    |> Enum.with_index()
    |> Enum.reduce_while(initial, fn {line, i}, {sections, end_at} ->
      case marker(String.trim_trailing(line, "\r")) do
        nil ->
          {:cont, {append_line(sections, line), end_at}}

        {"end", _attrs} ->
          sections = close_section(sections)
          end_at = length(sections) - 1

          if i == count - 2 and Enum.at(lines, i + 1) == "",
            do: {:halt, {sections, end_at}},
            else: {:cont, {sections, end_at}}

        {kind, attrs} ->
          sections = close_section(sections)
          {:cont, {sections ++ [%{kind: kind, attributes: attrs, lines: []}], end_at}}
      end
    end)
  end

  defp marker(line) do
    case Regex.run(~r/\A\]\]>openui:([a-z]+)(?:\?(.*))?\z/, line) do
      [_, kind] -> {kind, %{}}
      [_, kind, query] -> {kind, read_attributes(query)}
      nil -> nil
    end
  end

  defp append_line(sections, line) do
    List.update_at(sections, -1, fn s -> %{s | lines: s.lines ++ [line]} end)
  end

  # The newline (and its `\r`) before a marker is not part of the body.
  defp close_section(sections) do
    List.update_at(sections, -1, fn s ->
      case s.lines do
        [] -> s
        lines -> %{s | lines: List.update_at(lines, -1, &String.trim_trailing(&1, "\r"))}
      end
    end)
  end

  defp body(section), do: Enum.join(section.lines, "\n")

  defp last_index(list, value) do
    list
    |> Enum.with_index()
    |> Enum.reduce(-1, fn {v, i}, acc -> if v == value, do: i, else: acc end)
  end

  defp read_attributes(query) do
    query
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      {key, value} =
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {decode(k), decode(v)}
          [k] -> {decode(k), ""}
        end

      if key == "", do: acc, else: Map.put(acc, key, value)
    end)
  end

  # Same bytes as URLSearchParams: unreserved characters stay, space becomes `+`.
  defp encode(s) do
    s
    |> URI.encode(fn c -> (URI.char_unreserved?(c) and c != ?~) or c in [?*] end)
    |> String.replace("%20", "+")
  end

  defp decode(s) do
    s |> String.replace("+", " ") |> URI.decode()
  rescue
    ArgumentError -> s
  end
end
