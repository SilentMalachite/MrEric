defmodule MrEric.RAG.Index do
  @moduledoc """
  Builds an in-memory lexical RAG index from safe project files.
  """

  alias MrEric.RAG.Chunker
  alias MrEric.Tools.Policy

  @default_extensions ~w(.css .ex .exs .heex .html .js .json .lock .md .toml .ts .txt .yaml .yml)
  @default_ignored_dirs ~w(.elixir_ls .git _build cover deps node_modules
                           config priv/cert priv/secrets .serena .expert .idea .claude)
  @default_ignored_files [
    ~r/^\.env(\..*)?$/,
    ~r/^secrets?\.exs$/,
    ~r/^prod\.secret\.exs$/
  ]
  @default_ignored_extensions ~w(.pem .key .p12 .pfx .cer .crt .pkcs12 .jks .asc .gpg)
  @default_max_file_bytes 64_000

  # Dirs ignored only because they are likely to contain secrets; skipped when allow_secret_paths: true.
  @secret_dirs ~w(config priv/cert priv/secrets)

  def build(opts \\ []) do
    workspace = Policy.workspace_root(opts)

    if File.dir?(workspace) do
      paths =
        Keyword.get(opts, :paths) || Keyword.get(opts, :rag_paths) ||
          discover_paths(workspace, opts)

      {chunk_groups, errors, file_count} =
        Enum.reduce(paths, {[], [], 0}, fn path, {chunk_groups, errors, file_count} ->
          case index_path(path, workspace, opts) do
            {:ok, []} ->
              {chunk_groups, errors, file_count}

            {:ok, chunks} ->
              {[chunks | chunk_groups], errors, file_count + 1}

            {:error, error} ->
              {chunk_groups, [error | errors], file_count}
          end
        end)

      {:ok,
       %{
         workspace_root: workspace,
         chunks: chunk_groups |> Enum.reverse() |> List.flatten(),
         errors: Enum.reverse(errors),
         file_count: file_count,
         indexed_at: DateTime.utc_now()
       }}
    else
      {:error, :invalid_workspace}
    end
  end

  @doc """
  A cheap identity for what `build/1` would read, plus the paths it found.

  The walk is `File.lstat` only -- the same lstat `discover_paths/2` already
  performs -- so this costs no extra syscalls. Reading, chunking and
  tokenizing the files is the expensive half, and it is what a matching
  fingerprint lets the cache skip.

  `size` is part of the entry as well as `mtime`: mtime granularity is one
  second on some filesystems, and size catches most same-second edits. A
  same-second, same-size edit can still slip through; the alternative is
  hashing every file, which costs exactly what the cache exists to save.

  The digest is SHA-256 over the sorted entries, **not** `:erlang.phash2/1`.
  `phash2` answers in a 2^27 range, which is small enough to find collisions
  in a few hundred thousand tries -- two different sizes for the same path and
  mtime hashing alike. A fingerprint collision is a stale index served as
  fresh, which is the one failure this function exists to prevent.
  """
  def fingerprint(opts \\ []) do
    workspace = Policy.workspace_root(opts)

    if File.dir?(workspace) do
      entries =
        case Keyword.get(opts, :paths) || Keyword.get(opts, :rag_paths) do
          nil -> discover_entries(workspace, opts)
          paths -> Enum.map(paths, &stat_entry(workspace, to_string(&1)))
        end

      sorted = Enum.sort(entries)
      {:ok, digest(sorted), Enum.map(sorted, fn {path, _mtime, _size} -> path end)}
    else
      {:error, :invalid_workspace}
    end
  end

  defp digest(entries) do
    :crypto.hash(:sha256, :erlang.term_to_binary(entries, [:deterministic]))
  end

  # Entries from `discover_entries/2` were produced by a walk that already
  # stayed inside the workspace and already skipped symlinks. `opts[:paths]` is
  # caller-supplied and has had neither check, so it goes through `Policy` --
  # the same resolution `index_path/3` performs before reading. Without it a
  # `../../../etc/passwd` entry would be `lstat`ed, putting a file's existence,
  # mtime and size outside the workspace into the fingerprint. `Policy` is the
  # single authority on which paths RAG may touch; no second opinion here.
  defp stat_entry(workspace, relative_path) do
    case Policy.resolve_workspace_path(relative_path, workspace_root: workspace) do
      {:ok, absolute_path} -> lstat_entry(relative_path, absolute_path)
      {:error, reason} -> {relative_path, reason, -1}
    end
  end

  defp lstat_entry(relative_path, absolute_path) do
    case File.lstat(absolute_path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {relative_path, mtime, size}
      {:error, reason} -> {relative_path, reason, -1}
    end
  end

  defp discover_paths(workspace, opts) do
    workspace
    |> discover_entries(opts)
    |> Enum.map(fn {path, _mtime, _size} -> path end)
  end

  defp discover_entries(workspace, opts) do
    extensions = Keyword.get(opts, :include_extensions, @default_extensions)
    allow_secret = Keyword.get(opts, :allow_secret_paths, false)

    base_dirs =
      if allow_secret,
        do: @default_ignored_dirs -- @secret_dirs,
        else: @default_ignored_dirs

    ignored_dirs =
      (base_dirs ++ Keyword.get(opts, :extra_ignored_dirs, []))
      |> MapSet.new()

    ignored_files = @default_ignored_files ++ Keyword.get(opts, :extra_ignored_files, [])
    ignored_extensions = MapSet.new(@default_ignored_extensions)

    workspace
    |> discover_dir("", extensions, ignored_dirs, ignored_files,
                    ignored_extensions, allow_secret, [])
    |> Enum.reverse()
  end

  defp discover_dir(workspace, relative_dir, extensions, ignored_dirs,
                    ignored_files, ignored_extensions, allow_secret, acc) do
    dir = Path.join(workspace, relative_dir)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, acc ->
          relative_path = relative_path(relative_dir, entry)
          absolute_path = Path.join(workspace, relative_path)

          case File.lstat(absolute_path) do
            {:ok, %File.Stat{type: :directory}} ->
              cond do
                MapSet.member?(ignored_dirs, entry) -> acc
                MapSet.member?(ignored_dirs, relative_path) -> acc
                not allow_secret and MrEric.Tools.Policy.secret_path?(relative_path) -> acc
                true ->
                  discover_dir(workspace, relative_path, extensions, ignored_dirs,
                               ignored_files, ignored_extensions, allow_secret, acc)
              end

            {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
              cond do
                not indexed_extension?(relative_path, extensions) -> acc
                MapSet.member?(ignored_extensions, Path.extname(relative_path)) -> acc
                Enum.any?(ignored_files, &Regex.match?(&1, Path.basename(relative_path))) -> acc
                not allow_secret and MrEric.Tools.Policy.secret_path?(relative_path) -> acc
                true -> [{relative_path, mtime, size} | acc]
              end

            _other ->
              acc
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp index_path(path, workspace, opts) do
    with {:ok, absolute_path} <- Policy.resolve_workspace_path(path, workspace_root: workspace),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(absolute_path),
         :ok <- ensure_reasonable_size(size, opts),
         {:ok, content} <- File.read(absolute_path),
         :ok <- ensure_utf8(content) do
      relative_path = Policy.relative_path(absolute_path, workspace_root: workspace)
      {:ok, Chunker.chunk_text(relative_path, content, opts)}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, %{path: to_string(path), reason: {:unsupported_file_type, type}}}

      {:skip, reason} ->
        {:error, %{path: to_string(path), reason: reason}}

      {:error, reason} ->
        {:error, %{path: to_string(path), reason: reason}}
    end
  end

  defp ensure_reasonable_size(size, opts) do
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)

    if size <= max_file_bytes do
      :ok
    else
      {:skip, :too_large}
    end
  end

  defp ensure_utf8(content) do
    if String.valid?(content), do: :ok, else: {:skip, :binary_file}
  end

  defp relative_path("", entry), do: entry
  defp relative_path(relative_dir, entry), do: Path.join(relative_dir, entry)

  defp indexed_extension?(path, extensions), do: Path.extname(path) in extensions
end
