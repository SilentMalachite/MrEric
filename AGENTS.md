This is a Phoenix LiveView web application for orchestrating AI-agent runs.

## Core Rules

- Respond to users in Japanese.
- Start answers with the logical conclusion.
- You may use subagents when they are useful and the task is parallelizable.
- Do not change more than 3 files at once unless the user has explicitly allowed it.
- Run `mix precommit` after completing code changes, and fix any issues it reports.
- Use the included `Req` library for HTTP requests. Do not add `httpoison`, `tesla`, or `httpc`.
- Never implement ChatGPT Pro login, ChatGPT Web UI automation, cookie reuse, scraping, or any workflow that exposes browser/session secrets.

## Safety Boundaries

- Never expose API keys, Authorization headers, cookies, raw provider secrets, secret file contents, or process internals in PubSub events, assigns, templates, logs intended for users, traces, eval output, or browser-side JavaScript.
- File access must stay inside the configured workspace. Reject traversal, absolute paths outside the workspace, protected secret paths, and symlinks that escape the workspace.
- Protect `.env*`, private keys, `.pem`/`.key` files, credential/token/secret paths, `.git`, and `.ssh`.
- Do not implement `git commit`, `git push`, `git reset`, `git clean`, force push, or destructive automatic rollback inside the app.
- Real file writes are allowed only through `:apply_patch`, and only after a signed approval request is approved through `MrEric.Tools.Executor.execute_approved/2`.
- `:shell_command` and `:apply_patch` must always require approval. Do not bypass approval gates.

## AI Providers

- Provider implementations live under `MrEric.LLM`; `MrEric.OpenAIClient` is a backward-compatible wrapper.
- `MrEric.OpenAIClient` and `MrEric.LLM.OpenAICompat` talk to OpenAI-compatible `/v1/chat/completions` and `/v1/models` endpoints.
- Supported provider ids are `openai`, `grok`/`xai`, `openrouter`, `ollama`, and `lmstudio`/`llstudio`.
- Request-level `provider:` and `model:` opts should pass through to the LLM layer.
- Local providers default to `http://localhost:11434/v1` for Ollama and `http://localhost:1234/v1` for LM Studio.
- Production config in `config/runtime.exs` enforces required environment variables for the selected provider.
- OpenRouter may use `OPENROUTER_SITE_URL`/`SITE_URL` for `HTTP-Referer` and `OPENROUTER_APP_NAME` for `X-Title`.

## Runs And Events

- Start realtime execution through `MrEric.Runs.start_run/2`; it creates one `MrEric.Runs.RunWorker` under `MrEric.Runs.RunSupervisor`.
- `RunWorker` owns in-memory Run state, calls `MrEric.Orchestrator.stream(task, self(), opts)` in a task, applies events, broadcasts sanitized PubSub events, records completed runs, and ignores late chunks after cancellation.
- Run state is intentionally in-memory because this app currently has no Ecto repo configured. Do not add persistence unless the surrounding data layer changes.
- PubSub topics must be named exactly `"runs:#{run_id}"`.
- Valid UI roles are `:planner`, `:local_drafter`, `:cloud_drafter`, `:critic`, `:reviewer`, and `:synthesizer`. Keep role-specific UI panels stable and addressable by DOM IDs.
- LiveView should subscribe only to the current Run topic, process run events in `handle_info/2`, and unsubscribe when switching runs or terminating.
- Run event names are `:run_started`, `:stage_started`, `:stage_chunk`, `:stage_completed`, `:stage_failed`, `:run_completed`, `:run_failed`, and `:run_cancelled`.

## Tools And Patch Flow

- Tool implementations live under `MrEric.Tools` and must implement `MrEric.Tools.Tool`.
- Built-in tools are registered through `MrEric.Tools.Registry`: `:file_read`, `:file_write_proposal`, `:apply_patch`, `:shell_command`, `:git_status`, and `:git_diff`.
- All tool execution must go through `MrEric.Tools.Executor`, which calls `MrEric.Tools.Policy` before running a tool.
- `:file_write_proposal` may return proposed content and a diff, but it must not modify the filesystem.
- `:shell_command` must stay on a read-oriented allowlist plus read-only git subcommands, and must reject shell expansion, redirection, mutating commands, and unlisted commands.
- Tool PubSub events use the current run topic and include `:tool_started`, `:tool_approval_requested`, `:tool_approval_resolved`, `:tool_completed`, `:tool_failed`, `:tool_denied`, and `:tool_rejected`.
- `:apply_patch` accepts `%{path: path, patch: unified_diff}` or `%{changes: [%{path: path, before: before, after: after}]}`.
- Patch validation must run before approval is requested and again immediately before applying.
- `MrEric.Tools.PatchValidator` must reject workspace escapes, protected secret paths, symlink escapes, oversized patches, binary files or binary patches, missing update targets, stale `before` content, deletion patches, and disallowed create-file extensions.
- LiveView must show pending patch approvals with target file, summary, unified diff, risk level, Approve, and Reject controls.
- After approval and apply, show the resulting `git diff` and record changed file paths in Run history.
- Rollback is manual: users inspect the displayed `git diff` and revert through the Codex diff pane.

## Orchestrator Tool Loop

- `MrEric.Orchestrator.stream/3` may let `:planner`, `:critic`, and `:reviewer` request tools. Keep draft and synthesizer stages focused on text generation unless product scope changes.
- Tool requests must be emitted internally as `{:tool_requested, %{run_id: run_id, role: role, tool_name: tool_name, input: input, reason: reason, tool_call_id: id, reply_to: pid}}`.
- `RunWorker` is the only broker that calls `MrEric.Tools.Executor.request_tool/4`; Orchestrator must not bypass RunWorker, Registry, Policy, or approval events.
- `RunWorker` must set Run status to `:waiting_for_approval` while an approval request is pending, then return to running after approval resolution.
- Approved tools execute through the signed approval request only. Rejected approvals return an internal `{:tool_result, %{status: :rejected, error: reason}}`; Policy-denied tools return `status: :denied`.
- Orchestrator must append bounded tool results back into the next LLM prompt before continuing the same stage.
- OpenAI-compatible responses may include `choices[0].message.tool_calls`; parse only `id`, `function.name`, and JSON `function.arguments`.
- Local/non-tool-calling LLMs may request a tool only when the entire assistant message is a JSON object shaped like `%{"tool" => name, "input" => map, "reason" => text}`. Do not scrape arbitrary prose for executable JSON.
- Enforce `max_tool_calls_per_run`, `max_tool_calls_per_role`, `max_total_runtime_ms`, `max_context_chars`, and `max_tool_output_chars`.

## RAG And MCP Boundaries

- Basic RAG lives under `MrEric.RAG`: `Chunker`, `Index`, `Retriever`, and `context_for/2`.
- RAG must only index safe text files inside the workspace and must reuse `MrEric.Tools.Policy` path resolution.
- RAG is in-memory and lexical. Do not add vector DBs, mandatory embeddings, hybrid search, metadata indexing, or RAG status UI unless explicitly scoped.
- Planner may receive bounded `MrEric.RAG.context_for/2` context before its first model call. RAG failure must not fail the whole run.
- MCP extension points live under `MrEric.MCP.ClientBehaviour` and `MrEric.MCP.ToolAdapter`.
- Current MCP support is interface-level only. Do not add MCP server config, external MCP process startup, external tool discovery, MCP registry, MCP proxy, or MCP UI unless explicitly scoped.
- `RunWorker` may send internal `{:tool_result, ...}` replies to a trusted `reply_to` pid from a tool call payload. Never broadcast `reply_to`.

## Phase 9 Evals

- Phase 9 is a measurement and safety layer for the Phase 1-6 agent harness. Do not implement Phase 7-style advanced RAG features or Phase 8-style real MCP connectivity as part of Phase 9.
- Use `MrEric.LLM.FakeProvider` for deterministic tests and evals. It must never call external APIs, local model servers, ChatGPT Web UI, cookies, scraping, or MCP servers.
- Fake provider scenarios and scripts must be deterministic: same prompt plus same opts must produce the same response, tool call, error, or stream chunks.
- Golden eval cases live in `priv/evals/phase9_golden_cases.json`. Add cases with name, task, scenario, expected status/events/final substrings, approval action, optional requirements, and secret leak expectation.
- `mix mr_eric.evals` must run only against the fake provider. Do not add tests that require real OpenAI, OpenRouter, Grok, Ollama, LM Studio, or external MCP servers.
- Run trace is stored through `MrEric.Runs.Trace` from sanitized RunWorker/PubSub events. Trace output must pass redaction before UI, logs intended for users, eval output, or test diagnostics.
- Use `MrEric.Errors` for error classification and safe user-facing messages. Error text may contain provider secrets, so redact before exposing or storing it.
- Use `MrEric.Evals.SecretChecker` for final output, drafts, reviews, run trace, tool output, patch proposal/result, audit-like output, and testable LiveView render output.
- RAG evals are optional and run only when `MrEric.RAG.context_for/2` exists.
- MCP evals are optional and run only when Phase 5B MCP interface modules exist.
- Never use real API keys in tests. Use dummy secrets only, and never print the dummy secret value in failure messages when leak detection reports a hit.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components or use daisyUI if it is already integrated into the project.
- This project uses **daisyUI** for UI components.

- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
