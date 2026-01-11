# Whisp

macOSメニューバーアプリ。音声をリアルタイムでテキストに変換し、AIで後処理を行います。

- **リアルタイム音声認識**: Deepgramによるストリーミング文字起こし
- **AI後処理**: Google Geminiでフィラーワード除去、句読点追加、専門用語修正
- **低遅延**: 発話終了からクリップボードまで500ms以下を目標

## インストール

### 1. アプリのダウンロード

[Releases](https://github.com/your-repo/whisp/releases)から最新の`.dmg`ファイルをダウンロードし、`Whisp.app`をApplicationsフォルダにドラッグしてください。

### 2. 初回起動時の設定（未署名アプリのため必要）

このアプリはApple Developer Programに登録していないため、初回起動時にmacOSのGatekeeperによってブロックされます。以下のいずれかの方法で起動してください。

#### 方法A: システム設定から許可する（推奨）

1. Whisp.appをダブルクリックして開こうとする
2. 「開発元を確認できないため開けません」というダイアログが表示されたら「OK」をクリック
3. **システム設定** → **プライバシーとセキュリティ** を開く
4. 下にスクロールすると「"Whisp"は開発元を確認できないため、使用がブロックされました」と表示されている
5. **このまま開く** をクリック
6. パスワードを入力して許可

#### 方法B: ターミナルから拡張属性を削除する

ターミナルで以下のコマンドを実行してください：

```bash
xattr -cr /Applications/Whisp.app
```

その後、通常通りアプリを開けます。

### 3. マイクのアクセス許可

初回起動時にマイクへのアクセス許可を求めるダイアログが表示されます。**許可**をクリックしてください。

後から変更する場合は、**システム設定** → **プライバシーとセキュリティ** → **マイク** でWhispを有効にしてください。

## 設定

### APIキーの取得と設定

Whispを使用するには、以下の2つのAPIキーが必要です。

#### Deepgram（音声認識）

1. [Deepgram](https://deepgram.com/)でアカウントを作成
2. ダッシュボードからAPIキーを生成
3. Whispの設定画面で入力

#### Google Gemini（AI後処理）

1. [Google AI Studio](https://aistudio.google.com/)にアクセス
2. **Get API key** → **Create API key** でキーを生成
3. Whispの設定画面で入力

### グローバルショートカット

デフォルトは `Cmd+J` です。設定画面から変更できます。

## 使い方

1. メニューバーのWhispアイコンをクリックするか、ショートカットキー（デフォルト: `Cmd+J`）を押して録音開始
2. 話し終わったら再度クリックまたはショートカットキーで録音停止
3. 自動的にテキストがクリップボードにコピーされます（設定で自動ペーストも可能）

## 開発

```bash
# 依存関係のインストール
bun install

# 開発モードで起動
bun run tauri dev

# プロダクションビルド
bun run tauri build
```

## 技術スタック

- **Frontend**: React + TypeScript + Vite
- **Backend**: Rust + Tauri v2
- **Audio**: CPAL
- **STT**: Deepgram WebSocket API
- **Post-processing**: Google Gemini API

## ライセンス

MIT
