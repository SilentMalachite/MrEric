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

  test "index_bytes/1 counts the errors an index retains" do
    error = %{path: "a.md", reason: :too_large}
    idx = %{index([]) | errors: [error]}

    assert Cache.index_bytes(idx) == :erlang.external_size(error) + 200
  end

  test "an index of nothing but errors is still bounded" do
    key = Cache.key(workspace_root: "/errors-only")
    limit = Cache.fetch!(:max_cached_index_bytes)

    errors =
      for i <- 1..64 do
        %{path: String.duplicate("p", div(limit, 32)) <> "#{i}", reason: :too_large}
      end

    assert Cache.index_bytes(%{index([]) | errors: errors}) > limit
    assert :ok = Cache.put(key, 1, %{index([]) | errors: errors})
    assert Cache.fetch(key, 1) == :miss
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

  test "max_cached_total_bytes evicts the least recently read entries until the total fits" do
    # The third byte limit. `max_cached_index_bytes` and `max_cached_indexes`
    # each have a test; without this one the total-bytes branch of `evict/1`
    # could stop working and the suite would stay green.
    #
    # The limit is lowered rather than the indexes inflated: reaching 48 MB for
    # real would cost the suite ~150 MB of binaries to prove one comparison.
    previous = Application.get_env(:mr_eric, :rag_cache, [])
    on_exit(fn -> Application.put_env(:mr_eric, :rag_cache, previous) end)

    one = index([chunk(String.duplicate("x", 4_000), %{})])
    bytes = Cache.index_bytes(one)

    Application.put_env(
      :mr_eric,
      :rag_cache,
      Keyword.merge(previous, max_cached_total_bytes: bytes * 2)
    )

    # Only the total-bytes branch can fire: each index is far under the
    # per-index cap, and three keys are under `max_cached_indexes` (4).
    assert bytes < Cache.fetch!(:max_cached_index_bytes)
    assert 3 <= Cache.fetch!(:max_cached_indexes)

    [k1, k2, k3] = for i <- 1..3, do: Cache.key(workspace_root: "/total#{i}")

    :ok = Cache.put(k1, 1, one)
    :ok = Cache.put(k2, 1, one)

    # Re-reading k1 makes k2 the least recently read. `fetch/2` touches by
    # cast and `put/3` is a call, so from this process the touch is ordered
    # before the put that triggers the eviction.
    assert {:ok, _} = Cache.fetch(k1, 1)

    :ok = Cache.put(k3, 1, one)

    assert Cache.fetch(k2, 1) == :miss
    assert {:ok, _} = Cache.fetch(k1, 1)
    assert {:ok, _} = Cache.fetch(k3, 1)
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
