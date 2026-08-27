defmodule MrEric.Tools.Policy do
  @moduledoc """
  Policy checks for Phase 5A tools.

  The policy is intentionally conservative. Paths must stay inside the
  workspace, likely secret files are protected, and shell commands are
  read-oriented plus approval-gated.
  """

  alias MrEric.Tools.PatchValidator

  @known_tool_names ~w(file_read file_write_proposal apply_patch shell_command git_status git_diff)
  @allowed_shell_commands ~w(pwd ls cat sed grep rg git)
  @allowed_git_subcommands ~w(status diff log show)

  # Matched case-insensitively: macOS filesystems are case-insensitive by
  # default, so `.GIT/config` reaches the same bytes as `.git/config`.
  @protected_dir_segments ~w(.git .ssh)

  # Options that make an otherwise read-only program write. Matched against the
  # argv vector, so option order cannot defeat them the way it defeats the
  # positional patterns in @dangerous_command_patterns (`sed -E -i` slips past
  # `~r/(^|\s)sed\s+-i/`, `sed -i` does not).
  #
  # Adding a program to @allowed_shell_commands requires an entry here, or a
  # written argument in the spec for why the program has no mutating options.
  @mutating_options %{
    "sed" => [~r/^-{1,2}i/, ~r/^--in-place/]
  }

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
         :ok <- ensure_program_options_allowed(command),
         :ok <- ensure_command_paths_allowed(command, opts) do
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
    with {:ok, [program | args]} <- command_argv(command) do
      program = Path.basename(program)

      cond do
        program not in @allowed_shell_commands ->
          {:error, :dangerous_command}

        program == "git" and git_subcommand(args) not in @allowed_git_subcommands ->
          {:error, :dangerous_command}

        true ->
          :ok
      end
    end
  end

  defp git_subcommand(["-C", _path | rest]), do: git_subcommand(rest)
  defp git_subcommand(["--no-pager" | rest]), do: git_subcommand(rest)

  defp git_subcommand([arg | rest]) when is_binary(arg) do
    if String.starts_with?(arg, "-"), do: git_subcommand(rest), else: arg
  end

  defp git_subcommand([]), do: nil

  # Runs before the path check so a mutating option is reported as
  # :dangerous_command rather than as whatever its argument happens to resolve to.
  defp ensure_program_options_allowed(command) do
    with {:ok, [program | args]} <- command_argv(command) do
      denied = Map.get(@mutating_options, program, [])

      if Enum.any?(args, fn arg -> Enum.any?(denied, &Regex.match?(&1, arg)) end) do
        {:error, :dangerous_command}
      else
        :ok
      end
    end
  end

  defp ensure_command_paths_allowed(command, opts) do
    with {:ok, tokens} <- command_argv(command) do
      Enum.reduce_while(tokens, :ok, fn token, :ok ->
        case validate_command_token_path(token, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
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

  defp validate_command_token_path(token, opts) do
    case option_value_paths(token) do
      [] ->
        validate_plain_token_path(token, opts)

      values ->
        Enum.reduce_while(values, :ok, fn value, :ok ->
          case validate_plain_token_path(value, opts) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  # A path can hide inside an option token: `-fPATTERNS`, `--file=PATTERNS`.
  # The token as a whole expands to a harmless in-workspace string
  # (`<workspace>/--file=..`), so it must be taken apart before
  # `validate_plain_token_path/2` sees it. Clause order matters: the `--`
  # clause must shadow the single-letter one.
  defp option_value_paths("--" <> rest) do
    case String.split(rest, "=", parts: 2) do
      [_name, value] when value != "" -> [value]
      _no_value -> []
    end
  end

  defp option_value_paths(<<?-, letter, value::binary>>) when value != "" do
    if letter in ?a..?z or letter in ?A..?Z, do: [value], else: []
  end

  defp option_value_paths(_token), do: []

  defp validate_plain_token_path(token, opts) do
    cond do
      String.contains?(token, "://") ->
        :ok

      path = embedded_absolute_path(token) ->
        case resolve_workspace_path(path, opts) do
          {:ok, _path} -> :ok
          {:error, reason} -> {:error, reason}
        end

      token == ".." or String.starts_with?(token, "../") or String.contains?(token, "/../") ->
        {:error, :outside_workspace}

      String.starts_with?(token, "/") or String.starts_with?(token, "./") or
        String.contains?(token, "/") or secret_path?(token) ->
        case resolve_workspace_path(token, opts) do
          {:ok, _path} -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        :ok
    end
  end

  defp embedded_absolute_path(token) do
    case Regex.run(~r/(?:^|=)(\/[^=\s]+)/, token) do
      [_, path] -> path
      _no_path -> nil
    end
  end
end
