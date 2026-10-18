defmodule LiveRender.OpenUI.Parser.Stream do
  @moduledoc """
  Incremental parser for chunked input (language.md, section 4).

      stream = Stream.new(library)
      {stream, result} = Stream.push(stream, "root = Stack([hea")
      {stream, result} = Stream.push(stream, "der])\\nheader = Text(\\"Hi\\")\\n")
      {stream, result} = Stream.finish(stream)

  Chunks may split anything, including names, strings and fence markers. A statement completes
  when its ending newline has arrived and the next line's first token has arrived and is not `?`.
  Completed statements are parsed once. The text after them (the pending tail) is parsed on every
  chunk after implicit closing; a pending statement that needed closing never replaces a completed
  one. When the prepared text no longer starts with the completed prefix (a fence opener arrived,
  say), the cache is dropped and parsing starts again. `finish/1` ends the stream: the tail becomes
  completed, and the result equals `LiveRender.OpenUI.Parser.parse/2` on the full text.
  """

  alias LiveRender.OpenUI.{Lexer, Library, Parser, Source, Statements}
  alias LiveRender.OpenUI.Parser.Result

  defstruct lib: nil,
            buffer: "",
            prepared: "",
            completed_end: 0,
            completed: [],
            completed_count: 0

  @type t :: %__MODULE__{}

  @doc "Starts a stream for `library`."
  @spec new(Library.t()) :: t()
  def new(%Library{} = lib), do: %__MODULE__{lib: lib}

  @doc "Appends a chunk and returns the current result."
  @spec push(t(), String.t()) :: {t(), Result.t()}
  def push(%__MODULE__{} = s, chunk), do: result(%{s | buffer: s.buffer <> chunk}, false)

  @doc "Ends the stream and returns the final result."
  @spec finish(t()) :: {t(), Result.t()}
  def finish(%__MODULE__{} = s), do: result(s, true)

  @doc """
  Sets the full text received so far. Only the new suffix is processed; if `text` does not extend
  the previous text, the stream starts over.
  """
  @spec set(t(), String.t(), boolean()) :: {t(), Result.t()}
  def set(%__MODULE__{} = s, text, complete? \\ false) do
    s = if String.starts_with?(text, s.buffer), do: s, else: reset(s)
    result(%{s | buffer: text}, complete?)
  end

  @doc "The text received so far."
  def text(%__MODULE__{buffer: b}), do: b

  defp reset(s), do: %__MODULE__{lib: s.lib}

  defp result(s, complete?) do
    prepared = Source.prepare(s.buffer, streaming: not complete?)

    s =
      if String.starts_with?(prepared, binary_part(s.prepared, 0, s.completed_end)),
        do: %{s | prepared: prepared},
        else: %{s | prepared: prepared, completed_end: 0, completed: [], completed_count: 0}

    s = scan_completed(s)

    # `incomplete` describes the whole text, as in a batch parse: a closing bracket that does not
    # match leaves an earlier bracket open even when the pending tail closes by itself.
    {_, whole_incomplete} = Source.auto_close(s.prepared)

    pending_text =
      s.prepared
      |> binary_part(s.completed_end, byte_size(s.prepared) - s.completed_end)
      |> String.trim()

    cond do
      pending_text == "" and s.completed == [] ->
        {s, %Result{incomplete: true}}

      pending_text == "" ->
        {s, Parser.build(Parser.dedupe(s.completed), s.lib, whole_incomplete, s.completed_count)}

      true ->
        {closed, incomplete} = Source.auto_close(pending_text)
        raws = closed |> Lexer.tokenize() |> Statements.split()
        completed_ids = MapSet.new(s.completed, & &1.id)

        pending =
          raws
          |> Enum.reject(&(incomplete and not complete? and MapSet.member?(completed_ids, &1.id)))
          |> Enum.map(&Parser.classify(&1, closed))

        cond do
          raws == [] and s.completed == [] ->
            {s, %Result{incomplete: incomplete or whole_incomplete}}

          true ->
            partial_ref =
              if complete?, do: nil, else: partial_ref(s.buffer, pending_text, pending)

            stmts = Parser.dedupe(s.completed ++ pending)
            count = s.completed_count + length(raws)
            {s, Parser.build(stmts, s.lib, incomplete or whole_incomplete, count, partial_ref)}
        end
    end
  end

  # Completed statements past the watermark move into the cache.
  defp scan_completed(s) do
    tail = binary_part(s.prepared, s.completed_end, byte_size(s.prepared) - s.completed_end)
    raws = tail |> Lexer.tokenize(s.completed_end) |> Statements.split()
    confirmed = Enum.take_while(raws, & &1.confirmed)

    case confirmed do
      [] ->
        s

      _ ->
        new = Enum.map(confirmed, &Parser.classify(&1, s.prepared))
        last = List.last(confirmed)

        %{
          s
          | completed: s.completed ++ new,
            completed_count: s.completed_count + length(new),
            completed_end: last.stop + 1
        }
    end
  end

  # A `$name` at the very end of the raw text may still be growing (`$d` of `$dishes`).
  defp partial_ref(buffer, pending_text, pending) do
    with [tail] <- Regex.run(~r/\$\w+\z/, buffer),
         true <- String.ends_with?(pending_text, tail),
         earlier = binary_part(pending_text, 0, byte_size(pending_text) - byte_size(tail)),
         false <- Regex.match?(~r/#{Regex.escape(tail)}(?!\w)/, earlier) do
      {tail, MapSet.new(pending, & &1.id)}
    else
      _ -> nil
    end
  end
end
