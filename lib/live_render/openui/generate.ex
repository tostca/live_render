if Code.ensure_loaded?(ReqLLM) do
  defmodule LiveRender.OpenUI.Generate do
    @moduledoc """
    Streams OpenUI 1.0 responses from a model with ReqLLM.

        def handle_event("ask", %{"q" => q}, socket) do
          LiveRender.OpenUI.Generate.stream("anthropic:claude-haiku-4-5", q,
            library: @library,
            conversation: socket.assigns.conversation,
            tools: MyApp.OpenUITools,
            tool_context: %{actor: socket.assigns.current_user},
            pid: self()
          )

          {:noreply, assign(socket, text: "", streaming?: true)}
        end

        def handle_info({:live_render, :openui_chunk, chunk}, socket),
          do: {:noreply, update(socket, :text, &(&1 <> chunk))}

        def handle_info({:live_render, :openui_done, text}, socket),
          do: {:noreply, assign(socket, streaming?: false, text: text)}

    and render the text with `LiveRender.OpenUI.Live` (`response={@text} streaming={@streaming?}`).

    Messages sent to `:pid`: `{:live_render, :openui_chunk, text}` for each chunk,
    `{:live_render, :openui_done, full_text}` at the end, and `{:live_render, :error, reason}`.
    """

    alias LiveRender.OpenUI.{Conversation, Prompt, ToolHost}

    @doc """
    Starts a streaming request in a task. Options:

      * `:library` (required) — the `LiveRender.OpenUI.Library`
      * `:pid` (required) — receives the messages above
      * `:conversation` — a `LiveRender.OpenUI.Conversation` with earlier turns
      * `:tools`, `:tool_context` — host tools; their descriptors teach `Query` and `Mutation`
      * `:edit` — the current program text: edit mode, the model answers with a patch
      * `:prompt` — extra `LiveRender.OpenUI.Prompt.generate/2` options
      * `:model_opts` — passed to `ReqLLM.stream_text/3`
    """
    @spec stream(String.t(), String.t(), keyword()) :: {:ok, pid()}
    def stream(model, prompt, opts) do
      pid = Keyword.fetch!(opts, :pid)
      messages = messages(prompt, opts)
      model_opts = Keyword.get(opts, :model_opts, [])

      Task.start(fn ->
        case ReqLLM.stream_text(model, messages, model_opts) do
          {:ok, response} ->
            send(pid, {:live_render, :openui_done, forward_tokens(response, pid)})

          {:error, reason} ->
            send(pid, {:live_render, :error, reason})
        end
      end)
    end

    # Sends each token as it arrives and returns the full text.
    defp forward_tokens(response, pid) do
      response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce("", fn token, acc ->
        send(pid, {:live_render, :openui_chunk, token})
        acc <> token
      end)
    end

    @doc "Generates a complete response. Same options as `stream/3` without `:pid`."
    @spec generate(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def generate(model, prompt, opts) do
      case ReqLLM.generate_text(model, messages(prompt, opts), Keyword.get(opts, :model_opts, [])) do
        {:ok, response} -> {:ok, ReqLLM.Response.text(response)}
        {:error, _} = error -> error
      end
    end

    @doc "The system prompt and messages a request sends. Useful to inspect or log."
    @spec messages(String.t(), keyword()) :: list()
    def messages(prompt, opts) do
      library = Keyword.fetch!(opts, :library)
      edit = opts[:edit]

      descriptors = ToolHost.descriptors(opts[:tools], Keyword.get(opts, :tool_context, %{}))

      prompt_opts =
        opts
        |> Keyword.get(:prompt, [])
        |> Keyword.put_new(:tools, descriptors)
        |> Keyword.put_new(:edit_mode, is_binary(edit))

      system = Prompt.generate(library, prompt_opts)
      history = opts |> Keyword.get(:conversation, Conversation.new()) |> Conversation.for_model()

      [ReqLLM.Context.system(system)] ++
        Enum.map(history, &to_context/1) ++ [ReqLLM.Context.user(user_text(prompt, edit))]
    end

    defp to_context(%{role: :user, content: c}), do: ReqLLM.Context.user(c)
    defp to_context(%{role: :assistant, content: c}), do: ReqLLM.Context.assistant(c)

    # In edit mode the host sends the current program with the request (prompt.md, section 6.4).
    defp user_text(prompt, edit) when is_binary(edit),
      do: "Current program:\n```openui-lang\n#{edit}\n```\n\n#{prompt}"

    defp user_text(prompt, _), do: prompt
  end
end
