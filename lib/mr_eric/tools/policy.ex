defmodule MrEric.Tools.Policy do
  @moduledoc """
  Policy checks for Phase 5A tools.

  The policy is intentionally conservative. Paths must stay inside the
  workspace, likely secret files are protected, and shell commands are
  read-oriented plus approval-gated.
  """

  alias MrEric.Tools.PatchValidator

  @known_tool_names ~w(file_read file_write_proposal apply_patch shell_command git_status git_diff)
  @allowed_shell_commands ~w(pwd ls cat grep rg git)
  @allowed_git_subcommands ~w(status diff log show)

  # Matched case-insensitively: macOS filesystems are case-insensitive by
  # default, so `.GIT/config` reaches the same bytes as `.git/config`.
  @protected_dir_segments ~w(.git .ssh)

  # Per-program argument grammar. An option is accepted only if it appears here;
  # a value is resolved as a path only if the entry says the option takes one.
  #
  # `short` is keyed by SINGLE CHARACTERS so bundles decompose correctly
  # (`-nf../x` is `-n` then `-f ../x`, not an opaque token). Values are `:flag`
  # (no argument) or `:path` / `:pattern` / `:literal` (takes an argument,
  # attached or as the next token).
  #
  # `:literal` asserts that leaving the value unchecked is safe for THAT option,
  # AND that the option's value is mandatory. Use `:literal_optional` when the
  # real grammar is `[=<value>]` -- a mandatory-value model would swallow the
  # following operand, removing it from path classification.
  #
  # `:path_pattern_source` is a path that ALSO supplies the search pattern
  # (`grep -f`, `rg --file`). With one of these present the program has no
  # pattern operand, so every bare operand is a file.
  #
  # When unsure, use `:path`. Never add a lookup default -- absence must refuse.
  @git_subcommands %{
    "status" => %{
      short: %{"s" => :flag, "b" => :flag, "z" => :flag},
      long: %{
        "--short" => :flag,
        # `--branch` is deliberately absent: the frozen @dangerous_command_patterns
        # rule `git\b.*\b(...|branch|...)\b` matches the option name, so the entry
        # would be unreachable. The short spelling `-b` is not shadowed.
        "--porcelain" => :flag,
        "--long" => :flag,
        # `--untracked-files[=<mode>]` -- optional value.
        "--untracked-files" => :literal_optional
      },
      operands: :paths
    },
    "diff" => %{
      short: %{"w" => :flag, "M" => :flag, "B" => :flag, "U" => :literal},
      long: %{
        "--stat" => :flag,
        "--cached" => :flag,
        "--staged" => :flag,
        "--name-only" => :flag,
        "--name-status" => :flag,
        "--numstat" => :flag,
        "--shortstat" => :flag,
        "--no-color" => :flag,
        "--find-renames" => :flag,
        "--unified" => :literal,
        # `--color[=<when>]` -- optional value.
        "--color" => :literal_optional
      },
      operands: :paths
    },
    "log" => %{
      short: %{"n" => :literal},
      long: %{
        "--oneline" => :flag,
        "--stat" => :flag,
        "--graph" => :flag,
        "--reverse" => :flag,
        "--no-color" => :flag,
        "--max-count" => :literal,
        "--format" => :literal,
        "--pretty" => :literal,
        "--since" => :literal,
        "--until" => :literal,
        "--author" => :literal
      },
      operands: :paths
    },
    "show" => %{
      short: %{},
      long: %{
        "--stat" => :flag,
        "--name-only" => :flag,
        "--oneline" => :flag,
        "--no-color" => :flag,
        "--format" => :literal,
        "--pretty" => :literal
      },
      operands: :paths
    }
  }

  @program_grammar %{
    "pwd" => %{short: %{"P" => :flag, "L" => :flag}, long: %{}, operands: :none},
    "cat" => %{
      short: %{"n" => :flag, "b" => :flag, "s" => :flag},
      long: %{},
      operands: :paths
    },
    # `-L` (dereference symlinks) is absent on purpose.
    "ls" => %{
      short: %{
        "1" => :flag,
        "a" => :flag,
        "A" => :flag,
        "l" => :flag,
        "h" => :flag,
        "r" => :flag,
        "t" => :flag,
        "S" => :flag,
        "F" => :flag,
        "d" => :flag,
        "p" => :flag,
        "R" => :flag,
        "G" => :flag
      },
      # `--color[=WHEN]` -- optional value; a following token is an operand.
      long: %{"--color" => :literal_optional},
      operands: :paths
    },
    # grep's `-L` is "files without match" and is harmless; rg's `-L` is
    # "follow symlinks" and is not. Per-program tables make that expressible.
    #
    # `-R` (--dereference-recursive) is absent for the same reason `rg -L` and
    # `ls -L` are: it follows symlinks out of the workspace. Whether it does so
    # depends on which grep is on PATH (BSD grep does not, GNU grep and ugrep
    # do), and a boundary must not depend on that. `-r` gives the recursion
    # without the dereference.
    "grep" => %{
      short: %{
        "r" => :flag,
        "n" => :flag,
        "i" => :flag,
        "H" => :flag,
        "h" => :flag,
        "c" => :flag,
        "l" => :flag,
        "L" => :flag,
        "w" => :flag,
        "x" => :flag,
        "v" => :flag,
        "E" => :flag,
        "F" => :flag,
        "o" => :flag,
        "q" => :flag,
        "s" => :flag,
        "e" => :pattern,
        "f" => :path_pattern_source,
        "m" => :literal,
        "A" => :literal,
        "B" => :literal,
        "C" => :literal
      },
      long: %{
        "--regexp" => :pattern,
        "--file" => :path_pattern_source,
        "--color" => :literal_optional,
        "--include" => :literal,
        "--exclude" => :literal,
        # GNU's long form of `-r`; `--dereference-recursive` is absent.
        "--recursive" => :flag,
        "--line-number" => :flag,
        "--ignore-case" => :flag,
        "--fixed-strings" => :flag,
        "--extended-regexp" => :flag,
        "--word-regexp" => :flag,
        "--invert-match" => :flag,
        "--count" => :flag,
        "--files-with-matches" => :flag,
        "--files-without-match" => :flag
      },
      operands: :pattern_then_paths
    },
    # `--pre`, `--hostname-bin` (execute a program), `-L` / `--follow`
    # (leave the workspace via symlinks) are absent on purpose.
    #
    # So are `--hidden` and `-u` / `--unrestricted`: they exist to defeat rg's
    # default skipping of hidden and gitignored files, which is what keeps
    # `rg <term> .` from reading `.env`. `grep -r` has no such default and its
    # exposure is recorded in the spec's Section 4 as an accepted gap.
    "rg" => %{
      short: %{
        "n" => :flag,
        "N" => :flag,
        "i" => :flag,
        "w" => :flag,
        "x" => :flag,
        "v" => :flag,
        "c" => :flag,
        "l" => :flag,
        "F" => :flag,
        "S" => :flag,
        "s" => :flag,
        "H" => :flag,
        "e" => :pattern,
        "f" => :path_pattern_source,
        "m" => :literal,
        "A" => :literal,
        "B" => :literal,
        "C" => :literal,
        "g" => :literal,
        "t" => :literal
      },
      long: %{
        "--version" => :flag,
        "--regexp" => :pattern,
        "--file" => :path_pattern_source,
        "--glob" => :literal,
        "--type" => :literal,
        "--color" => :literal,
        "--max-count" => :literal,
        "--no-heading" => :flag,
        "--line-number" => :flag,
        "--fixed-strings" => :flag,
        "--ignore-case" => :flag,
        "--word-regexp" => :flag,
        "--invert-match" => :flag,
        "--count" => :flag,
        "--files-with-matches" => :flag
      },
      operands: :pattern_then_paths
    },
    # `-c` / `--config-env` (name a program via config), `--git-dir`,
    # `--work-tree`, `--exec-path`, `--namespace` are absent on purpose.
    "git" => %{
      short: %{"C" => :path},
      long: %{"--no-pager" => :flag},
      operands: {:subcommand, @git_subcommands}
    }
  }

  # The grammar keys ARE the allow-list. Fail the build if they drift.
  if Enum.sort(Map.keys(@program_grammar)) != Enum.sort(@allowed_shell_commands) do
    raise "@program_grammar and @allowed_shell_commands drifted"
  end

  if Enum.sort(Map.keys(@git_subcommands)) != Enum.sort(@allowed_git_subcommands) do
    raise "@git_subcommands and @allowed_git_subcommands drifted"
  end

  @forbidden_shell_syntax [
    ~r/[;&|$`\\'"(){}\[\]*?<>~!]/,
    ~r/\n/
  ]

  @dangerous_command_patterns [
    ~r/(^|\s)rm\s+/,
    ~r/(^|\s)rmdir\s+/,
    ~r/(^|\s)mv\s+/,
    ~r/(^|\s)cp\s+/,
    ~r/(^|\s)chmod\s+/,
    ~r/(^|\s)chown\s+/,
    ~r/(^|\s)sudo(\s|$)/,
    ~r/(^|\s)su(\s|$)/,
    ~r/(^|\s)dd\s+/,
    ~r/(^|\s)mkfs(\.|\s|$)/,
    ~r/(^|\s)(shutdown|reboot|halt)(\s|$)/,
    ~r/(^|\s)(kill|pkill|killall)(\s|$)/,
    ~r/(^|\s)(curl|wget)\s+/,
    ~r/(^|\s)(ssh|scp|rsync)\s+/,
    ~r/(^|\s)tee\s+/,
    ~r/(^|\s)truncate\s+/,
    ~r/(^|\s)touch\s+/,
    ~r/(^|\s)mkdir\s+/,
    ~r/(^|\s)sed\s+-i/,
    ~r/(^|\s)perl\s+-pi/,
    ~r/(^|\s)git\b.*\b(add|commit|push|reset|clean|checkout|switch|branch|merge|rebase|restore|tag)\b/,
    ~r/(^|\s)mix\s+deps\.clean\b.*--all/,
    ~r/(^|[^<])>{1,2}/
  ]

  def authorize(tool, args, opts \\ []) do
    with {:ok, tool_name} <- normalize_tool_name(tool) do
      authorize_tool(tool_name, normalize_args(args), opts)
    end
  end

  def resolve_workspace_path(path, opts \\ []) do
    workspace = workspace_root(opts)

    with {:ok, path} <- normalize_path(path),
         expanded <- expand_path(path, workspace),
         :ok <- ensure_inside_workspace(expanded, workspace),
         :ok <- ensure_no_symlink_segments(expanded, workspace),
         :ok <- ensure_not_secret(expanded, workspace) do
      {:ok, expanded}
    end
  end

  def workspace_root(opts \\ []) do
    opts
    |> Keyword.get(:workspace_root, File.cwd!())
    |> Path.expand()
  end

  def relative_path(path, opts \\ []) do
    path
    |> Path.expand()
    |> Path.relative_to(workspace_root(opts))
  end

  def known_key(key) when is_atom(key), do: key

  def known_key(key) when is_binary(key) do
    case key do
      "path" -> :path
      "content" -> :content
      "patch" -> :patch
      "changes" -> :changes
      "before" -> :before
      "after" -> :after
      "command" -> :command
      "max_bytes" -> :max_bytes
      "staged" -> :staged
      "tool" -> :tool
      "args" -> :args
      "approval_id" -> :approval_id
      "approval_token" -> :approval_token
      "tool_call_id" -> :tool_call_id
      "reason" -> :reason
      "requested_at" -> :requested_at
      other -> other
    end
  end

  def known_key(key), do: key

  def normalize_args(args) when is_map(args) do
    Map.new(args, fn {key, value} -> {known_key(key), value} end)
  end

  def normalize_args(_args), do: %{}

  def arg(args, key) do
    args = normalize_args(args)
    Map.get(args, key) || Map.get(args, Atom.to_string(key))
  end

  @doc """
  Splits an already-authorized command string into an argv vector.

  Uses the same tokenizer as `authorize/3`, so the argv that gets executed is by
  construction the argv that was validated. This performs no safety checks of
  its own — callers must run `authorize/3` first.
  """
  @spec command_argv(term()) :: {:ok, [String.t(), ...]} | {:error, :invalid_args}
  def command_argv(command) when is_binary(command) do
    case command_tokens(command) do
      [] -> {:error, :invalid_args}
      tokens -> {:ok, tokens}
    end
  end

  def command_argv(_command), do: {:error, :invalid_args}

  @doc false
  # Read-only view of the argument grammar, for the table-driven test that
  # asserts every entry behaves per its declared value kind. Not public API.
  def __grammar__, do: %{programs: @program_grammar, git_subcommands: @git_subcommands}

  defp authorize_tool("file_read", args, opts) do
    with {:ok, _path} <- resolve_workspace_path(arg(args, :path), opts) do
      {:ok, %{approval_required?: false}}
    end
  end

  defp authorize_tool("file_write_proposal", args, opts) do
    with {:ok, _path} <- resolve_workspace_path(arg(args, :path), opts) do
      {:ok, %{approval_required?: false}}
    end
  end

  defp authorize_tool("apply_patch", args, opts) do
    with {:ok, _proposal} <- PatchValidator.validate(args, opts) do
      {:ok,
       %{
         approval_required?: true,
         reason: "Patch application requires explicit user approval."
       }}
    end
  end

  defp authorize_tool("shell_command", args, opts) do
    command = arg(args, :command)

    with {:ok, command} <- normalize_command(command),
         :ok <- ensure_safe_command(command),
         :ok <- ensure_argv_allowed(command, opts) do
      {:ok,
       %{
         approval_required?: true,
         reason: "Shell commands require explicit user approval."
       }}
    end
  end

  defp authorize_tool("git_status", _args, _opts), do: {:ok, %{approval_required?: false}}

  defp authorize_tool("git_diff", args, opts) do
    case arg(args, :path) do
      nil ->
        {:ok, %{approval_required?: false}}

      "" ->
        {:ok, %{approval_required?: false}}

      path ->
        with {:ok, _path} <- resolve_workspace_path(path, opts) do
          {:ok, %{approval_required?: false}}
        end
    end
  end

  defp authorize_tool(_tool, _args, _opts), do: {:error, :unknown_tool}

  defp normalize_tool_name(name) when is_atom(name) do
    normalized = Atom.to_string(name)

    if normalized in @known_tool_names do
      {:ok, normalized}
    else
      {:error, :unknown_tool}
    end
  end

  defp normalize_tool_name(name) when is_binary(name) do
    if name in @known_tool_names do
      {:ok, name}
    else
      {:error, :unknown_tool}
    end
  end

  defp normalize_tool_name(_name), do: {:error, :unknown_tool}

  defp normalize_path(path) when is_binary(path) do
    path = String.trim(path)

    if path == "" do
      {:error, :invalid_args}
    else
      {:ok, path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_args}

  defp expand_path(path, workspace) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, workspace)
    end
  end

  defp ensure_inside_workspace(path, workspace) do
    if path == workspace or String.starts_with?(path, workspace <> "/") do
      :ok
    else
      {:error, :outside_workspace}
    end
  end

  defp ensure_not_secret(path, workspace) do
    relative = Path.relative_to(path, workspace)

    if secret_path?(relative) do
      {:error, :secret_file}
    else
      :ok
    end
  end

  defp ensure_no_symlink_segments(path, workspace) do
    path
    |> Path.relative_to(workspace)
    |> Path.split()
    |> Enum.reduce_while({:ok, workspace}, fn segment, {:ok, current} ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :outside_workspace}}
        {:ok, _stat} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:halt, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true when the given workspace-relative path is considered secret-bearing.
  Used by `resolve_workspace_path/2` to gate tool access and by `MrEric.RAG.Index`
  to exclude such files from the lexical index. Single source of truth.

  Directory-segment matching (`.git`, `.ssh`) is case-insensitive because macOS
  filesystems are case-insensitive by default.
  """
  @spec secret_path?(Path.t()) :: boolean()
  def secret_path?(relative) do
    segments = Path.split(relative)
    basename = Path.basename(relative)

    Enum.any?(segments, &(String.downcase(&1) in @protected_dir_segments)) or
      String.starts_with?(String.downcase(basename), ".env") or
      Regex.match?(~r/^id_(rsa|dsa|ecdsa|ed25519)$/i, basename) or
      Regex.match?(~r/\.(pem|key|p12|pfx)$/i, basename) or
      Regex.match?(~r/(secret|credential|token)/i, relative)
  end

  defp normalize_command(command) when is_binary(command) do
    command = String.trim(command)

    if command == "" do
      {:error, :invalid_args}
    else
      {:ok, command}
    end
  end

  defp normalize_command(_command), do: {:error, :invalid_args}

  defp ensure_safe_command(command) do
    if Enum.any?(@forbidden_shell_syntax, &Regex.match?(&1, command)) or
         Enum.any?(@dangerous_command_patterns, &Regex.match?(&1, command)) do
      {:error, :dangerous_command}
    else
      ensure_allowed_shell_command(command)
    end
  end

  defp ensure_allowed_shell_command(command) do
    with {:ok, [program | _args]} <- command_argv(command) do
      cond do
        # The allow-listed string must be the string that gets resolved and
        # executed, so a path-shaped program token is rejected outright rather
        # than reduced to its basename.
        String.contains?(program, "/") -> {:error, :dangerous_command}
        program not in @allowed_shell_commands -> {:error, :dangerous_command}
        true -> :ok
      end
    end
  end

  # Parses the argv vector against the program's grammar. This is the only
  # place a command token becomes a path: a token is resolved because the
  # grammar says its option takes a path, never because it happens to contain
  # a "/". Unknown option or unknown program => refusal, by absence.
  defp ensure_argv_allowed(command, opts) do
    with {:ok, [program | args]} <- command_argv(command),
         {:ok, grammar} <- fetch_grammar(program) do
      walk_argv(args, grammar, opts, false)
    end
  end

  defp fetch_grammar(program) do
    case Map.fetch(@program_grammar, program) do
      {:ok, grammar} -> {:ok, grammar}
      :error -> {:error, :dangerous_command}
    end
  end

  # `pattern_seen?` tracks whether a :pattern already arrived (via -e/--regexp
  # or a bare operand), which decides how the next bare operand is classified.
  defp walk_argv([], _grammar, _opts, _pattern_seen?), do: :ok

  defp walk_argv(["--" | rest], grammar, opts, pattern_seen?),
    do: walk_operands(rest, grammar, opts, pattern_seen?)

  # A bare "-" means stdin.
  defp walk_argv(["-" | rest], grammar, opts, pattern_seen?),
    do: walk_argv(rest, grammar, opts, pattern_seen?)

  defp walk_argv(["--" <> _ = token | rest], grammar, opts, pattern_seen?) do
    {name, attached} =
      case String.split(token, "=", parts: 2) do
        [name] -> {name, :none}
        [name, value] -> {name, value}
      end

    case Map.fetch(grammar.long, name) do
      :error ->
        {:error, :dangerous_command}

      {:ok, :flag} ->
        if attached == :none,
          do: walk_argv(rest, grammar, opts, pattern_seen?),
          else: {:error, :dangerous_command}

      {:ok, kind} ->
        consume_value(kind, attached, rest, grammar, opts, pattern_seen?)
    end
  end

  defp walk_argv(["-" <> bundle | rest], grammar, opts, pattern_seen?),
    do: walk_bundle(String.graphemes(bundle), rest, grammar, opts, pattern_seen?)

  # `git <subcommand>`: the subcommand owns the rest of the vector, under its
  # own grammar. Must precede the generic operand clause.
  defp walk_argv([operand | rest], %{operands: {:subcommand, table}}, opts, _pattern_seen?) do
    case Map.fetch(table, operand) do
      :error -> {:error, :dangerous_command}
      {:ok, sub_grammar} -> walk_argv(rest, sub_grammar, opts, false)
    end
  end

  defp walk_argv([operand | rest], grammar, opts, pattern_seen?) do
    case classify_operand(operand, grammar, opts, pattern_seen?) do
      {:ok, seen?} -> walk_argv(rest, grammar, opts, seen?)
      {:error, reason} -> {:error, reason}
    end
  end

  # After `--`, every remaining token is an operand.
  defp walk_operands([], _grammar, _opts, _pattern_seen?), do: :ok

  defp walk_operands([operand | rest], %{operands: {:subcommand, table}}, opts, _seen?) do
    case Map.fetch(table, operand) do
      :error -> {:error, :dangerous_command}
      {:ok, sub_grammar} -> walk_operands(rest, sub_grammar, opts, false)
    end
  end

  defp walk_operands([operand | rest], grammar, opts, pattern_seen?) do
    case classify_operand(operand, grammar, opts, pattern_seen?) do
      {:ok, seen?} -> walk_operands(rest, grammar, opts, seen?)
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_bundle([], rest, grammar, opts, pattern_seen?),
    do: walk_argv(rest, grammar, opts, pattern_seen?)

  defp walk_bundle([char | more], rest, grammar, opts, pattern_seen?) do
    case Map.fetch(grammar.short, char) do
      :error ->
        {:error, :dangerous_command}

      {:ok, :flag} ->
        walk_bundle(more, rest, grammar, opts, pattern_seen?)

      {:ok, kind} ->
        attached = if more == [], do: :none, else: Enum.join(more)
        consume_value(kind, attached, rest, grammar, opts, pattern_seen?)
    end
  end

  # An optional-value option binds ONLY in the attached / `=value` form. A
  # following separate token is an operand, not the value -- consuming it would
  # remove it from operand classification and so from the path check.
  defp consume_value(:literal_optional, :none, rest, grammar, opts, pattern_seen?),
    do: walk_argv(rest, grammar, opts, pattern_seen?)

  defp consume_value(:literal_optional, _value, rest, grammar, opts, pattern_seen?),
    do: walk_argv(rest, grammar, opts, pattern_seen?)

  # Otherwise the value is whatever was attached, else the next token.
  defp consume_value(_kind, :none, [], _grammar, _opts, _pattern_seen?),
    do: {:error, :invalid_args}

  defp consume_value(kind, :none, [value | rest], grammar, opts, pattern_seen?) do
    with :ok <- classify_value(kind, value, opts) do
      walk_argv(rest, grammar, opts, pattern_seen? or pattern_source?(kind))
    end
  end

  defp consume_value(kind, value, rest, grammar, opts, pattern_seen?) do
    with :ok <- classify_value(kind, value, opts) do
      walk_argv(rest, grammar, opts, pattern_seen? or pattern_source?(kind))
    end
  end

  # With a pattern source present the program has no pattern operand, so the
  # next bare operand must be classified as a path, not swallowed as the regex.
  defp pattern_source?(:pattern), do: true
  defp pattern_source?(:path_pattern_source), do: true
  defp pattern_source?(_kind), do: false

  defp classify_value(kind, value, opts) when kind in [:path, :path_pattern_source] do
    case resolve_workspace_path(value, opts) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A pattern is a regex and is never opened; a literal is enumerated per
  # option precisely because leaving its value unchecked is safe there.
  defp classify_value(:pattern, _value, _opts), do: :ok
  defp classify_value(:literal, _value, _opts), do: :ok

  defp classify_operand(_operand, %{operands: :none}, _opts, _seen?),
    do: {:error, :dangerous_command}

  defp classify_operand(operand, %{operands: :paths}, opts, seen?) do
    with :ok <- classify_value(:path, operand, opts), do: {:ok, seen?}
  end

  # The first bare operand is the pattern unless one already arrived via
  # -e/--regexp; everything after it is a path.
  defp classify_operand(operand, %{operands: :pattern_then_paths}, opts, seen?) do
    if seen? do
      with :ok <- classify_value(:path, operand, opts), do: {:ok, true}
    else
      {:ok, true}
    end
  end

  defp command_tokens(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&clean_command_token/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_command_token(token) do
    token
    |> String.trim(~s('"`))
    |> String.trim_trailing(",;")
  end
end
