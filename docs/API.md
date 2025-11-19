# API ドキュメント

MrEric のプログラマティック API リファレンスです。

## 目次

- [MrEric モジュール](#mreric-モジュール)
- [MrEric.OpenAIClient モジュール](#mrericopenaiclilent-モジュール)
- [MrEric.Agent モジュール](#mrericagent-モジュール)

---

## MrEric モジュール

アプリケーションのメインモジュール。タスク実行と履歴管理の高レベル API を提供します。

### execute_task/1

タスクを実行します。

**シグネチャ:**
\`\`\`elixir
execute_task(task :: String.t()) :: {:ok, map()} | {:error, atom()}
\`\`\`

**パラメータ:**
- \`task\` - 実行するタスクの説明文字列

**戻り値:**
- \`{:ok, entry}\` - 成功時。entry には以下が含まれます：
  - \`task\` - タスクの説明
  - \`plan\` - 実行計画
  - \`code\` - 生成されたコード
  - \`inserted_at\` - 実行日時 (DateTime)
- \`{:error, :invalid_task}\` - タスクが空文字列または無効な場合

**例:**
\`\`\`elixir
# 基本的な使い方
{:ok, result} = MrEric.execute_task("Create a simple Phoenix controller")

IO.inspect(result.plan)
# => "1. Create controller file\n2. Define actions..."

# エラーハンドリング
case MrEric.execute_task("") do
  {:ok, result} -> handle_success(result)
  {:error, reason} -> handle_error(reason)
end
\`\`\`

---

### get_task_history/0

実行履歴を取得します。

**シグネチャ:**
\`\`\`elixir
get_task_history() :: [map()]
\`\`\`

**戻り値:**
- タスクエントリのリスト（新しい順）

**例:**
\`\`\`elixir
history = MrEric.get_task_history()

Enum.each(history, fn entry ->
  IO.puts("Task: #{entry.task}")
  IO.puts("Time: #{entry.inserted_at}")
end)
\`\`\`

---

### get_latest_task/0

最新のタスクを取得します。

**シグネチャ:**
\`\`\`elixir
get_latest_task() :: map() | nil
\`\`\`

**戻り値:**
- 最新のタスクエントリ、または履歴が空の場合は \`nil\`

**例:**
\`\`\`elixir
case MrEric.get_latest_task() do
  nil -> IO.puts("No tasks yet")
  task -> IO.puts("Latest: #{task.task}")
end
\`\`\`

---

## MrEric.OpenAIClient モジュール

OpenAI API との通信を担当するモジュール。全 OpenAI モデルをサポートします。

### chat_completion/2

チャット補完を実行します。

**シグネチャ:**
\`\`\`elixir
chat_completion(prompt :: String.t(), opts :: keyword()) :: String.t()
\`\`\`

**パラメータ:**
- \`prompt\` - 送信するプロンプト文字列
- \`opts\` - オプションのキーワードリスト
  - \`:model\` - 使用する OpenAI モデル（デフォルト: config で設定されたモデル）

**戻り値:**
- AI からの応答文字列

**利用可能なモデル:**
- \`"gpt-4o"\` - GPT-4o（推奨）
- \`"gpt-4o-mini"\` - GPT-4o Mini
- \`"gpt-4-turbo"\` - GPT-4 Turbo
- \`"gpt-4"\` - GPT-4
- \`"gpt-3.5-turbo"\` - GPT-3.5 Turbo
- \`"o1-preview"\` - O1 Preview
- \`"o1-mini"\` - O1 Mini

**例:**
\`\`\`elixir
# デフォルトモデルを使用
response = MrEric.OpenAIClient.chat_completion("Hello, AI!")
IO.puts(response)
# => "Hello! How can I assist you today?"

# 特定のモデルを指定
response = MrEric.OpenAIClient.chat_completion(
  "Write a haiku about Elixir",
  model: "gpt-4-turbo"
)

# 長いプロンプト
prompt = """
You are a helpful assistant.
Please explain Phoenix LiveView in simple terms.
"""
response = MrEric.OpenAIClient.chat_completion(prompt, model: "gpt-3.5-turbo")
\`\`\`

---

### stream_completion/3

ストリーミング形式でチャット補完を実行します。

**シグネチャ:**
\`\`\`elixir
stream_completion(prompt :: String.t(), pid :: pid(), opts :: keyword()) :: :ok
\`\`\`

**パラメータ:**
- \`prompt\` - 送信するプロンプト文字列
- \`pid\` - 応答を受信するプロセスの PID
- \`opts\` - オプションのキーワードリスト
  - \`:model\` - 使用する OpenAI モデル

**送信されるメッセージ:**
- \`{:chunk, text}\` - テキストチャンク
- \`{:complete, :ok}\` - ストリーミング完了

**例:**
\`\`\`elixir
# 基本的なストリーミング
MrEric.OpenAIClient.stream_completion("Tell me a story", self())

# メッセージ受信ループ
defp receive_stream(acc \\\\ "") do
  receive do
    {:chunk, text} ->
      IO.write(text)
      receive_stream(acc <> text)
    {:complete, :ok} ->
      IO.puts("\\n\\nComplete!")
      acc
  end
end

# GenServer での使用例
def handle_info({:chunk, text}, state) do
  updated_response = state.response <> text
  {:noreply, %{state | response: updated_response}}
end

def handle_info({:complete, :ok}, state) do
  {:noreply, %{state | loading: false}}
end

# 特定のモデルでストリーミング
MrEric.OpenAIClient.stream_completion(
  "Explain quantum computing",
  self(),
  model: "gpt-4o"
)
\`\`\`

---

## MrEric.Agent モジュール

タスクの実行とメモリ内ストレージを管理します。

### execute/1

タスクを実行して結果を保存します。

**シグネチャ:**
\`\`\`elixir
execute(task :: String.t()) :: {:ok, map()} | {:error, atom()}
\`\`\`

**パラメータ:**
- \`task\` - 実行するタスクの説明

**戻り値:**
- \`{:ok, entry}\` - 成功時
- \`{:error, reason}\` - エラー時

**例:**
\`\`\`elixir
{:ok, entry} = MrEric.Agent.execute("Create a new migration")
\`\`\`

---

### history/0

保存された履歴を取得します。

**シグネチャ:**
\`\`\`elixir
history() :: [map()]
\`\`\`

**戻り値:**
- エントリのリスト（新しい順）

**例:**
\`\`\`elixir
history = MrEric.Agent.history()
length(history)  # => 10
\`\`\`

---

## エラーハンドリング

### OpenAI API エラー

\`\`\`elixir
try do
  MrEric.OpenAIClient.chat_completion("Hello")
rescue
  error ->
    case error do
      %Req.TransportError{} ->
        Logger.error("Network error: #{inspect(error)}")
      _ ->
        Logger.error("Unexpected error: #{inspect(error)}")
    end
end
\`\`\`

### タスク実行エラー

\`\`\`elixir
case MrEric.execute_task(task) do
  {:ok, result} ->
    handle_success(result)
  {:error, :invalid_task} ->
    {:error, "Task cannot be empty"}
  {:error, reason} ->
    {:error, "Failed to execute: #{reason}"}
end
\`\`\`

---

## 設定

### デフォルトモデルの設定

\`config/config.exs\`:

\`\`\`elixir
config :mr_eric,
  openai_model: "gpt-4o"
\`\`\`

### テスト環境での設定

\`config/test.exs\`:

\`\`\`elixir
config :mr_eric,
  openai_req_options: [
    plug: {Req.Test, MrEric.OpenAIClientMock}
  ]
\`\`\`

---

## ベストプラクティス

### 1. エラーハンドリング

常に \`execute_task/1\` の戻り値をパターンマッチングで処理します：

\`\`\`elixir
case MrEric.execute_task(task) do
  {:ok, result} -> handle_result(result)
  {:error, reason} -> handle_error(reason)
end
\`\`\`

### 2. ストリーミングの使用

長い応答が予想される場合は、ストリーミング API を使用します：

\`\`\`elixir
# 非推奨: 長時間ブロック
response = MrEric.OpenAIClient.chat_completion(long_prompt)

# 推奨: ストリーミング
MrEric.OpenAIClient.stream_completion(long_prompt, self())
\`\`\`

### 3. モデルの選択

タスクに応じて適切なモデルを選択します：

\`\`\`elixir
# 高速・低コストタスク
chat_completion(prompt, model: "gpt-3.5-turbo")

# 高精度が必要なタスク
chat_completion(prompt, model: "gpt-4o")

# 推論が必要なタスク
chat_completion(prompt, model: "o1-preview")
\`\`\`

### 4. タイムアウト処理

\`\`\`elixir
Task.async(fn ->
  MrEric.OpenAIClient.chat_completion(prompt)
end)
|> Task.await(30_000)  # 30秒タイムアウト
\`\`\`

---

## パフォーマンス考慮事項

### レート制限

OpenAI API にはレート制限があります。大量のリクエストを送信する場合は、適切な間隔を設けてください：

\`\`\`elixir
tasks
|> Enum.each(fn task ->
  MrEric.execute_task(task)
  Process.sleep(1000)  # 1秒待機
end)
\`\`\`

### 並行処理

\`\`\`elixir
tasks
|> Task.async_stream(
  fn task -> MrEric.execute_task(task) end,
  max_concurrency: 5,
  timeout: 30_000
)
|> Enum.to_list()
\`\`\`

---

## 参考資料

- [OpenAI API Documentation](https://platform.openai.com/docs)
- [Phoenix LiveView Guide](https://hexdocs.pm/phoenix_live_view)
- [Req Documentation](https://hexdocs.pm/req)
