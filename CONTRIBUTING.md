# Contributing to MrEric

まず、MrEric への貢献を検討していただきありがとうございます！🎉

このドキュメントは、プロジェクトへの貢献方法についてのガイドラインを提供します。

## 📋 目次

- [行動規範](#行動規範)
- [始め方](#始め方)
- [開発プロセス](#開発プロセス)
- [コーディング規約](#コーディング規約)
- [コミットメッセージ](#コミットメッセージ)
- [プルリクエスト](#プルリクエスト)
- [テスト](#テスト)
- [ドキュメント](#ドキュメント)

## 行動規範

このプロジェクトは、すべての参加者に対してオープンで歓迎的な環境を提供することを目指しています。

### 期待される行動

- 相手を尊重し、建設的なフィードバックを提供する
- 異なる視点や経験を歓迎する
- プロジェクトの目標に沿った貢献を行う
- コミュニティの他のメンバーを支援する

### 容認されない行動

- 嫌がらせ、差別的な発言、または攻撃的な行動
- スパムやトロール行為
- プライバシーの侵害
- その他の非倫理的または非専門的な行為

## 始め方

### 1. リポジトリのフォーク

```bash
# GitHub でフォークボタンをクリック
git clone https://github.com/YOUR_USERNAME/MrEric.git
cd MrEric
```

### 2. 開発環境のセットアップ

```bash
# 依存関係のインストール
mix setup

# 環境変数の設定
export OPENAI_API_KEY="your-api-key"

# サーバーの起動
mix phx.server
```

### 3. ブランチの作成

```bash
git checkout -b feature/your-feature-name
```

## 開発プロセス

### Issue の作成

新機能やバグ修正を始める前に、Issue を作成してください：

1. 既存の Issue を確認して重複を避ける
2. 明確なタイトルと説明を付ける
3. 可能であれば、再現手順や期待される動作を記載する

### ブランチ命名規則

- `feature/` - 新機能
- `fix/` - バグ修正
- `docs/` - ドキュメントのみの変更
- `refactor/` - リファクタリング
- `test/` - テストの追加・修正
- `chore/` - ビルドプロセスや補助ツールの変更

例:
```
feature/add-anthropic-support
fix/streaming-timeout-issue
docs/update-api-reference
```

## コーディング規約

### Elixir スタイルガイド

このプロジェクトは標準の Elixir スタイルガイドに従います：

```elixir
# 良い例
def execute_task(task) when is_binary(task) and task != "" do
  Agent.execute(task)
end

# 悪い例
def execute_task(task) do
  if is_binary(task) and task != "" do
    Agent.execute(task)
  end
end
```

### 重要なルール

1. **常に `mix format` を実行**
   ```bash
   mix format
   ```

2. **`mix precommit` を必ず実行**
   ```bash
   mix precommit
   ```

3. **モジュール doc を追加**
   ```elixir
   @moduledoc """
   Brief description of the module.
   """
   ```

4. **関数 doc を追加（public 関数のみ）**
   ```elixir
   @doc """
   Executes a task and returns the result.
   
   ## Examples
   
       iex> execute_task("Create controller")
       {:ok, %{task: "...", ...}}
   """
   def execute_task(task) do
     # implementation
   end
   ```

5. **Credo 警告に対処**
   ```bash
   mix credo --strict
   ```

### Phoenix / LiveView ガイドライン

- LiveView は `<Layouts.app flash={@flash}>` で開始
- フォームは `to_form/2` と `@form` を使用
- HTTP リクエストは `:req` ライブラリを使用
- アイコンは `<.icon name="hero-..."/>` を使用

詳細は [AGENTS.md](./AGENTS.md) を参照してください。

## コミットメッセージ

### フォーマット

```
<type>: <subject>

<body>

<footer>
```

### Type

- `feat`: 新機能
- `fix`: バグ修正
- `docs`: ドキュメントのみの変更
- `style`: コードの意味に影響しない変更（空白、フォーマット等）
- `refactor`: バグ修正でも機能追加でもないコード変更
- `test`: テストの追加・修正
- `chore`: ビルドプロセスや補助ツールの変更

### 例

```
feat: add support for Anthropic Claude models

- Add AnthropicClient module
- Update model selection dropdown
- Add configuration options
- Include tests

Closes #123
```

```
fix: resolve streaming timeout issue

Increase default timeout from 30s to 60s for long responses.

Fixes #456
```

## プルリクエスト

### プルリクエストの作成

1. **変更を commit**
   ```bash
   git add .
   git commit -m "feat: add new feature"
   ```

2. **フォークに push**
   ```bash
   git push origin feature/your-feature-name
   ```

3. **GitHub で PR を作成**
   - 明確なタイトルと説明を付ける
   - 関連する Issue を参照する
   - スクリーンショットを追加（UI 変更の場合）

### PR チェックリスト

プルリクエストを送信する前に、以下を確認してください：

- [ ] `mix format` を実行した
- [ ] `mix precommit` が成功する
- [ ] すべてのテストが通る（`mix test`）
- [ ] 新機能にテストを追加した
- [ ] ドキュメントを更新した
- [ ] CHANGELOG.md を更新した（必要に応じて）
- [ ] コミットメッセージが規約に従っている

### レビュープロセス

1. メンテナーがコードレビューを行います
2. 変更が要求された場合は、対応してください
3. 承認後、メンテナーがマージします

## テスト

### テストの実行

```bash
# 全テストを実行
mix test

# 特定のファイルのテスト
mix test test/mr_eric/openai_client_test.exs

# カバレッジ付き
mix test --cover
```

### テストの作成

新機能には必ずテストを追加してください：

```elixir
defmodule MrEric.YourModuleTest do
  use ExUnit.Case
  
  describe "your_function/1" do
    test "returns expected result" do
      assert YourModule.your_function("input") == expected_output
    end
    
    test "handles edge cases" do
      assert YourModule.your_function("") == {:error, :invalid_input}
    end
  end
end
```

### Mocking

OpenAI API 呼び出しは必ず mock してください：

```elixir
# test/support/openai_mock.ex を参照
```

## ドキュメント

### ドキュメントの更新

以下のドキュメントを必要に応じて更新してください：

- `README.md` - メイン README
- `docs/API.md` - API リファレンス
- `CHANGELOG.md` - 変更履歴
- モジュール内のドキュメント（`@moduledoc`, `@doc`）

### ドキュメントの生成

```bash
mix docs
open doc/index.html
```

## 質問やサポート

- **Issue**: バグ報告や機能リクエスト
- **Discussions**: 一般的な質問や議論
- **Pull Request**: コードの貢献

## 謝辞

貢献してくださるすべての方に感謝します！ 🙏

---

質問がある場合は、Issue を作成するか、プロジェクトメンテナーに連絡してください。
