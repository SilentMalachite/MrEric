defmodule MrEric.RAG.CacheTest do
  use ExUnit.Case, async: false

  alias MrEric.RAG.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  defp index(chunks), do: %{chunks: chunks, workspace_root: "/w", errors: [], file_count: 1}

  defp chunk(content, terms) do
    %{
      id: "c",
      path: "a.md",
      start_line: 1,
      end_line: 1,
      content: content,
      terms: terms,
      path_terms: %{}
    }
  end

  test "fetch/2 misses on an unknown key" do
    assert Cache.fetch({:nothing, :here}, 1) == :miss
  end

  test "put/3 then fetch/2 with the same fingerprint hits" do
    key = Cache.key(workspace_root: "/w")
    idx = index([chunk("hello", %{"hello" => 1})])

    assert :ok = Cache.put(key, 42, idx)
    assert {:ok, ^idx} = Cache.fetch(key, 42)
  end

  test "fetch/2 reports :stale when the fingerprint moved" do
    key = Cache.key(workspace_root: "/w")

    assert :ok = Cache.put(key, 42, index([chunk("hello", %{"hello" => 1})]))
    assert Cache.fetch(key, 43) == :stale
  end

  test "allow_secret_paths is part of the key" do
    safe = Cache.key(workspace_root: "/w", allow_secret_paths: false)
    unsafe = Cache.key(workspace_root: "/w", allow_secret_paths: true)

    refute safe == unsafe

    assert :ok = Cache.put(unsafe, 1, index([chunk("SECRET", %{"secret" => 1})]))
    assert Cache.fetch(safe, 1) == :miss
  end

  test "every content-affecting option changes the key" do
    base = [workspace_root: "/w"]
    base_key = Cache.key(base)

    variants = [
      [include_extensions: ~w(.ex)],
      [max_file_bytes: 1_000],
      [chunk_size: 400],
      [chunk_overlap: 40],
      [extra_ignored_dirs: ["vendor"]],
      [extra_ignored_files: [~r/^ignore\.md$/]],
      [paths: ["README.md"]]
    ]

    for variant <- variants do
      refute Cache.key(base ++ variant) == base_key, "#{inspect(variant)} did not change the key"
    end
  end

  test "regex options are normalized rather than inspected" do
    a = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/])
    b = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/])
    c = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/i])

    assert a == b
    refute a == c
  end

  test "index_bytes/1 counts content and term-key bytes plus per-entry overhead" do
    idx = index([chunk("abcd", %{"ab" => 1, "cde" => 1})])

    # 4 content bytes + (2 + 48) + (3 + 48) + 200 per-chunk = 305
    assert Cache.index_bytes(idx) == 305
  end

  test "an index over max_cached_index_bytes is not stored" do
    key = Cache.key(workspace_root: "/big")
    limit = Cache.fetch!(:max_cached_index_bytes)
    huge = index([chunk(String.duplicate("x", limit + 1), %{})])

    assert :ok = Cache.put(key, 1, huge)
    assert Cache.fetch(key, 1) == :miss
  end

  test "max_cached_indexes evicts the least recently read entry" do
    limit = Cache.fetch!(:max_cached_indexes)
    keys = for i <- 1..(limit + 1), do: Cache.key(workspace_root: "/w#{i}")
    small = index([chunk("x", %{})])

    [first | rest] = keys
    Enum.each(keys, fn key -> :ok = Cache.put(key, 1, small) end)

    assert Cache.fetch(first, 1) == :miss
    assert Enum.all?(Enum.take(rest, -limit), &match?({:ok, _}, Cache.fetch(&1, 1)))
  end

  test "fetch!/1 raises for an unknown limit key" do
    assert_raise FunctionClauseError, fn -> Cache.fetch!(:no_such_limit) end
  end

  test "the documented defaults are the ones in use" do
    assert Cache.fetch!(:max_cached_index_bytes) == 24_000_000
    assert Cache.fetch!(:max_cached_total_bytes) == 48_000_000
    assert Cache.fetch!(:max_cached_indexes) == 4
  end
end
