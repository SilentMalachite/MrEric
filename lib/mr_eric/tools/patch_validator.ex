defmodule MrEric.Tools.PatchValidator do
  @moduledoc """
  Validates patch proposals before they can be approved or applied.
  """

  alias MrEric.Tools.Policy

  @max_patch_bytes 200_000
  @allowed_create_extensions ~w(
    .c .css .csv .eex .ex .exs .heex .html .js .json .leex .lock .md .mdx
    .scss .svg .toml .txt .xml .yaml .yml
  )

  def validate(args, opts \\ []) do
    args = normalize_map(args)

    cond do
      is_list(get(args, :changes)) ->
        validate_changes(get(args, :changes), opts)

      is_binary(get(args, :patch)) ->
        validate_unified_patch(args, opts)

      true ->
        {:error, :invalid_args}
    end
  end

  def max_patch_bytes, do: @max_patch_bytes

  defp validate_changes(changes, opts) when changes != [] do
    with :ok <- ensure_patch_size(changes) do
      changes
      |> Enum.map(&validate_change(&1, opts))
      |> collect_validations()
      |> case do
        {:ok, validated_changes} ->
          diff = Enum.map_join(validated_changes, "\n", &change_diff/1)
          changed_files = Enum.map(validated_changes, & &1.path)

          {:ok,
           %{
             mode: :changes,
             changes: validated_changes,
             changed_files: changed_files,
             diff: diff,
             summary: summary(changed_files)
           }}

        error ->
          error
      end
    end
  end

  defp validate_changes(_changes, _opts), do: {:error, :invalid_args}

  defp validate_change(change, opts) do
    change = normalize_map(change)
    path = get(change, :path)
    before = get(change, :before) || ""
    proposed = get(change, :after)

    with :ok <- ensure_not_deletion(proposed),
         :ok <- ensure_text_patch([before, proposed]),
         {:ok, full_path} <- Policy.resolve_workspace_path(path, opts),
         {:ok, current} <- validate_current_file(full_path, before, opts) do
      {:ok,
       %{
         path: Policy.relative_path(full_path, opts),
         full_path: full_path,
         before: current,
         after_content: proposed
       }}
    end
  end

  defp validate_unified_patch(args, opts) do
    patch = get(args, :patch)
    expected_path = get(args, :path)

    with :ok <- ensure_patch_size(patch),
         :ok <- ensure_text_patch([patch]),
         :ok <- ensure_not_binary_patch(patch),
         :ok <- ensure_unified_patch_is_not_deletion(patch),
         {:ok, patch_paths} <- extract_patch_paths(patch, expected_path),
         {:ok, validated_paths} <- validate_patch_paths(patch_paths, patch, opts),
         :ok <- ensure_git_apply_check(patch, opts) do
      changed_files = Enum.map(validated_paths, & &1.path)

      {:ok,
       %{
         mode: :unified_diff,
         patch: patch,
         changed_files: changed_files,
         diff: patch,
         summary: summary(changed_files)
       }}
    end
  end

  defp validate_current_file(full_path, before, opts) do
    case File.read(full_path) do
      {:ok, current} ->
        with :ok <- ensure_regular_file(full_path),
             :ok <- ensure_text_patch([current]),
             :ok <- ensure_before_matches(current, before) do
          {:ok, current}
        end

      {:error, :enoent} ->
        with :ok <- ensure_create_before_empty(before),
             :ok <- ensure_allowed_create_extension(Policy.relative_path(full_path, opts)) do
          {:ok, ""}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_patch_paths(paths, patch, opts) do
    creation_paths = creation_paths(patch)

    paths
    |> Enum.map(fn path ->
      with {:ok, full_path} <- Policy.resolve_workspace_path(path, opts),
           :ok <- validate_patch_target(full_path, path in creation_paths, opts) do
        {:ok, %{path: Policy.relative_path(full_path, opts), full_path: full_path}}
      end
    end)
    |> collect_validations()
  end

  defp validate_patch_target(full_path, true, opts) do
    if File.exists?(full_path) do
      {:error, :file_already_exists}
    else
      ensure_allowed_create_extension(Policy.relative_path(full_path, opts))
    end
  end

  defp validate_patch_target(full_path, false, _opts) do
    case File.read(full_path) do
      {:ok, content} ->
        with :ok <- ensure_regular_file(full_path),
             :ok <- ensure_text_patch([content]) do
          :ok
        end

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :binary_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_patch_size(content) when is_binary(content) do
    if byte_size(content) > @max_patch_bytes, do: {:error, :patch_too_large}, else: :ok
  end

  defp ensure_patch_size(changes) when is_list(changes) do
    size =
      changes
      |> Enum.map(&normalize_map/1)
      |> Enum.reduce(0, fn change, acc ->
        acc + byte_size(to_string(get(change, :path) || "")) +
          byte_size(to_string(get(change, :before) || "")) +
          byte_size(to_string(get(change, :after) || ""))
      end)

    if size > @max_patch_bytes, do: {:error, :patch_too_large}, else: :ok
  end

  defp ensure_text_patch(contents) do
    if Enum.any?(contents, &(is_binary(&1) and String.contains?(&1, <<0>>))) do
      {:error, :binary_file}
    else
      :ok
    end
  end

  defp ensure_not_binary_patch(patch) do
    if String.contains?(patch, "GIT binary patch") or
         Regex.match?(~r/^Binary files .+ differ$/m, patch) do
      {:error, :binary_file}
    else
      :ok
    end
  end

  defp ensure_not_deletion(nil), do: {:error, :deletion_forbidden}
  defp ensure_not_deletion(_after), do: :ok

  defp ensure_unified_patch_is_not_deletion(patch) do
    if String.contains?(patch, "deleted file mode") or
         Regex.match?(~r/^\+\+\+\s+\/dev\/null/m, patch) do
      {:error, :deletion_forbidden}
    else
      :ok
    end
  end

  defp ensure_before_matches(current, before) do
    if current == to_string(before), do: :ok, else: {:error, :before_mismatch}
  end

  defp ensure_create_before_empty(before) do
    if before in [nil, ""], do: :ok, else: {:error, :before_mismatch}
  end

  defp ensure_allowed_create_extension(path) do
    extension = path |> Path.extname() |> String.downcase()
    basename = Path.basename(path)

    cond do
      basename in [".gitignore", ".formatter.exs"] ->
        :ok

      extension in @allowed_create_extensions ->
        :ok

      true ->
        {:error, :file_not_found}
    end
  end

  defp extract_patch_paths(patch, expected_path) do
    paths =
      patch
      |> String.split("\n")
      |> Enum.flat_map(&diff_line_paths/1)
      |> Enum.reject(&(&1 in [nil, "/dev/null"]))
      |> Enum.map(&strip_diff_prefix/1)
      |> Enum.uniq()

    expected_paths =
      expected_path
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&strip_diff_prefix/1)

    paths =
      case {paths, expected_paths} do
        {[], [_ | _]} -> expected_paths
        {_paths, []} -> paths
        {_paths, _expected} -> paths
      end

    cond do
      paths == [] ->
        {:error, :invalid_patch}

      expected_paths != [] and Enum.any?(paths, &(&1 not in expected_paths)) ->
        {:error, :invalid_patch}

      true ->
        {:ok, paths}
    end
  end

  defp diff_line_paths("--- " <> rest), do: [diff_header_path(rest)]
  defp diff_line_paths("+++ " <> rest), do: [diff_header_path(rest)]

  defp diff_line_paths("diff --git " <> rest) do
    rest
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&strip_diff_prefix/1)
  end

  defp diff_line_paths(_line), do: []

  defp diff_header_path(rest) do
    rest
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp strip_diff_prefix(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.replace_prefix("a/", "")
    |> String.replace_prefix("b/", "")
  end

  defp strip_diff_prefix(path), do: path

  defp creation_paths(patch) do
    lines = String.split(patch, "\n")

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if String.starts_with?(line, "--- /dev/null") do
        lines
        |> Enum.at(index + 1, "")
        |> diff_line_paths()
        |> Enum.reject(&(&1 in [nil, "/dev/null"]))
        |> Enum.map(&strip_diff_prefix/1)
      else
        []
      end
    end)
  end

  defp ensure_git_apply_check(patch, opts) do
    with_patch_file(patch, fn patch_path ->
      workspace = Policy.workspace_root(opts)

      case System.cmd("git", ["apply", "--check", "--whitespace=nowarn", patch_path],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> {:error, :before_mismatch}
      end
    end)
  end

  defp with_patch_file(patch, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "mr-eric-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}.diff"
      )

    File.write!(path, patch)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp collect_validations(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp change_diff(change) do
    current_lines = diff_lines(change.before)
    proposed_lines = diff_lines(change.after_content)

    Enum.join(
      ["--- a/#{change.path}", "+++ b/#{change.path}", "@@ -1 +1 @@"]
      |> Kernel.++(Enum.map(current_lines, &("-" <> &1)))
      |> Kernel.++(Enum.map(proposed_lines, &("+" <> &1))),
      "\n"
    ) <> "\n"
  end

  defp diff_lines(""), do: []
  defp diff_lines(content), do: String.split(content, "\n", trim: true)

  defp summary([path]), do: "1 file will change: #{path}"
  defp summary(paths), do: "#{length(paths)} files will change"

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {Policy.known_key(key), value}
      pair -> pair
    end)
  end

  defp normalize_map(_value), do: %{}

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
