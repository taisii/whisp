# Whisp - 音声入力アプリ 実装計画

## 目的と理想的な挙動
- グローバルショートカット（Option+Space）で即座に録音開始し、リアルタイムに文字が確定していく
- 発話終了から500ms以内に整形済みテキストが確定し、クリップボードに出力される
- フィラー除去・句読点・技術用語補正が自動で効いており、再編集の必要が少ない
- ユーザー操作は「ショートカット押下」以外ほぼ不要

---

## 確定仕様

### 基本操作
| 項目 | 仕様 |
|------|------|
| **アプリ名** | Whisp |
| **ショートカット** | Option+Space（初期値、設定で変更可能） |
| **録音方式** | トグル方式（1回押しで開始、もう1回で終了） |
| **VAD（自動終了）** | MVPでは非対応（手動終了のみ） |

### 技術スタック
| 項目 | 採用技術 |
|------|----------|
| **対応OS** | macOSのみ |
| **フレームワーク** | Tauri v2 |
| **フロントエンド** | React + TypeScript |
| **パッケージマネージャー** | bun |
| **STT** | Deepgram Nova-3（ストリーミング） |
| **音声形式** | Linear16 PCM（非圧縮・MVP最優先） |
| **LLM後処理** | Gemini 3 Flash |
| **APIキー管理** | ローカル設定ファイル（`~/.config/whisp/config.toml`） |
| **主要プラグイン** | global-shortcut / clipboard-manager / notification / autostart |

### UI/UX
| 項目 | 仕様 |
|------|------|
| **アプリ形態** | メニューバーアプリ（タスクトレイ常駐） |
| **録音中フィードバック** | アイコン変化のみ（録音中=赤、待機中=グレー） |
| **完了通知** | サウンドのみ（短い完了音） |
| **エラー通知** | macOS通知センター |
| **自動起動** | 対応（ログイン項目に追加可能） |
| **履歴機能** | MVPでは非対応 |

### LLM後処理
| 項目 | 仕様 |
|------|------|
| **対応言語** | 自動判定（日本語/英語） |
| **技術用語辞書** | MVPでは非対応（LLMの知識のみ） |
| **フィラー除去対象** | 拡張フィラー（えーと、あのー、なんか、こう、まあ、ちょっと等） |
| **出力形式** | プレーンテキスト |
| **プロンプトカスタマイズ** | MVPでは非対応 |

### 設定画面
| 項目 | 仕様 |
|------|------|
| **設定項目** | APIキー（Deepgram、Gemini）/ ショートカット変更 |
| **自動ペースト** | ON/OFF切替（デフォルトON） |
| **マイク権限エラー時** | システム環境設定を開く |

---

## スコープ

### インスコープ（MVP）
- Tauriアプリ（macOS）
- グローバルショートカット（Option+Space、設定で変更可能）
- マイク録音（Linear16 PCM）
- Deepgram Nova-3のリアルタイムSTT
- Gemini 3 Flash による後処理（フィラー除去、句読点、技術用語修正）
- クリップボード出力
- 自動ペースト（Cmd+Vシミュレーション）
- メニューバーアプリUI
- 設定画面（APIキー入力）
- ログイン時自動起動

### アウトスコープ（後回し）
- 画面コンテキスト認識
- 独自STTモデル
- 音声波形・リアルタイムテキスト表示
- VAD（自動終了検出）
- 履歴機能
- 技術用語辞書のカスタマイズ
- プロンプトのカスタマイズ
- Opus圧縮送信（帯域最適化）

---

## 非機能要件（目標）
| 項目 | 目標値 |
|------|--------|
| **レイテンシ** | 500ms以内（発話終了→最終テキスト確定） |
| **精度** | 90%以上（LLM補正込み） |
| **安定性** | 30分連続利用でクラッシュなし |
| **プライバシー** | 音声データは必要最小限の送信のみ |

---

## 音声フォーマット方針（macOS最優先）
- MVPは **Linear16 PCM（非圧縮）** を採用し、実装を簡潔化する
- `cpal`のデフォルトサンプルレートを取得し、Deepgramの`sample_rate`に一致させる
- 1ch（mono）固定で送信し、`encoding=linear16`でストリーミングする

---

## アーキテクチャ

```
Option+Space
       ↓
メニューバーアイコン → 赤に変化
       ↓
録音開始（Linear16 PCM / デバイス既定サンプルレート）
       ↓
Deepgram ストリーミング STT（WebSocket）
  - encoding=linear16
  - sample_rate=デバイス既定値
  - channels=1
       ↓
部分結果の集約
       ↓
ショートカット再押下で録音終了
       ↓
Gemini 3 Flash 後処理
  ├── フィラー除去（えーと、あのー、なんか等）
  ├── 句読点追加
  └── 技術用語修正
       ↓
クリップボード出力
       ↓
Cmd+V を自動送信（自動ペースト）
       ↓
完了サウンド再生
アイコン → グレーに戻る
```

---

## ディレクトリ構成

```
whisp/
├── src-tauri/           # Rustバックエンド
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── shortcut.rs      # グローバルショートカット
│   │   ├── recorder.rs      # マイク録音（Linear16 PCM）
│   │   ├── stt_client.rs    # Deepgram WebSocket
│   │   ├── post_processor.rs # Gemini API呼び出し
│   │   ├── clipboard.rs     # クリップボード操作
│   │   ├── key_sender.rs    # キーボード送信（Cmd+V）
│   │   ├── config.rs        # 設定ファイル管理
│   │   ├── notification.rs  # macOS通知
│   │   └── sound.rs         # 完了サウンド
│   ├── Cargo.toml
│   └── tauri.conf.json
├── src/                 # Reactフロントエンド
│   ├── App.tsx
│   ├── main.tsx
│   ├── components/
│   │   └── Settings.tsx     # 設定画面
│   ├── hooks/
│   │   └── useTauriEvents.ts
│   └── styles/
├── package.json
├── bun.lockb
├── tsconfig.json
└── vite.config.ts
```

---

## 設定ファイル形式

**場所**: `~/.config/whisp/config.toml`

```toml
[api_keys]
deepgram = "your-deepgram-api-key"
gemini = "your-gemini-api-key"
```

---

## LLM後処理プロンプト

```
以下の音声認識結果を修正してください。修正後のテキストのみを出力してください。

修正ルール:
1. フィラー（えーと、あのー、えー、なんか、こう、まあ、ちょっと）を除去
2. 技術用語の誤認識を修正（例: "リアクト"→"React", "ユーズステート"→"useState"）
3. 句読点を適切に追加
4. 言語は自動判定（日本語/英語）

入力: {stt_result}
```

---

## 実装フェーズ

### Phase 1: 環境構築
- Tauri v2プロジェクト初期化（bun create tauri-app）
- React + TypeScript設定
- ディレクトリ構成の作成
- 設定ファイル管理の実装（config.rs）

**受け入れ条件**
- `bun tauri dev` でアプリが起動する
- メニューバーにアイコンが表示される
- 設定ファイルの読み書きができる

### Phase 2: グローバルショートカット
- Option+Spaceの実装（初期値）
- ショートカット押下でイベント発火
- capabilities権限の追加

**受け入れ条件**
- ショートカット押下でRustからフロントエンドにイベントが飛ぶ
- 他アプリがフォーカス中でも動作する

### Phase 3: マイク録音
- マイク権限の要求
- 権限がない場合のシステム環境設定への誘導
- Linear16 PCMでの録音
- 録音開始/停止のトグル制御
- メニューバーアイコンの状態変化

**受け入れ条件**
- ショートカットで録音開始/停止ができる
- アイコンが録音状態を反映する
- Linear16 PCMの音声データが取得できる

### Phase 4: Deepgram STT統合
- WebSocket接続の確立
- Linear16 PCM音声ストリームの送信
- `encoding=linear16` / `sample_rate` / `channels=1` の指定
- 部分結果/最終結果の取得
- 接続エラー時の通知

**受け入れ条件**
- 10秒の発話で文字起こし結果が得られる
- 接続失敗時にmacOS通知が表示される

### Phase 5: Gemini後処理
- Gemini 3 Flash API呼び出し
- プロンプトによるテキスト整形
- フィラー除去・句読点追加の動作確認

**受け入れ条件**
- STT結果がLLMで整形される
- フィラーが除去される
- 句読点が自然に入る

### Phase 6: 出力統合
- クリップボードへのテキスト出力
- Cmd+Vの自動送信（自動ペースト）
- 完了サウンドの再生
- 全体フローの結合

**受け入れ条件**
- 変換後テキストがクリップボードに入る
- 自動ペーストが主要アプリで動作する
- 完了時にサウンドが鳴る
- ショートカット→録音→STT→LLM→クリップボードの一連の流れが動く

### Phase 7: 設定画面
- APIキー入力フォーム
- 設定の保存/読み込み
- ショートカット変更UI
- メニューバーアイコンクリックで設定画面表示

**受け入れ条件**
- アイコンクリックで設定画面が開く
- APIキーを入力・保存できる
- ショートカットを変更・保存できる
- 保存したキーが次回起動時に読み込まれる

### Phase 8: MVP仕上げ
- エラー処理の整理（接続失敗、権限なし、APIエラー）
- ログイン時自動起動の設定
- レイテンシ測定ログ

**受け入れ条件**
- 連続利用で落ちない
- ログイン時に自動起動できる
- エラー時に適切な通知が出る

---

## 主要コンポーネント詳細

### ShortcutListener（shortcut.rs）
- Option+Spaceの検出
- グローバルショートカットの登録/解除
- イベント発火

### Recorder（recorder.rs）
- cpal crateでマイク入力取得
- i16へ量子化してLinear16 PCMとして送出
- 録音状態の管理（Recording / Stopped）

### SttClient（stt_client.rs）
- tokio-tungsteniteでWebSocket接続
- Deepgram Nova-3エンドポイントへの接続
- 音声ストリーム送信
- 部分結果/最終結果のパース

### PostProcessor（post_processor.rs）
- reqwestでGemini API呼び出し
- プロンプトの構築
- レスポンスのパース

### ClipboardOutput（clipboard.rs）
- Tauri公式Clipboardプラグインでクリップボード操作
- テキストの書き込み

### KeySender（key_sender.rs）
- enigo crateでCmd+Vを送信
- macOSアクセシビリティ許可の導線を提供

### NotificationManager（notification.rs）
- Tauri公式Notificationプラグインで通知送信
- エラーメッセージの表示

### SoundPlayer（sound.rs）
- 完了サウンドの再生
- rodio crateの使用

---

## 依存クレート（Rust）

```toml
[dependencies]
tauri = { version = "2", features = ["tray-icon"] }
tokio = { version = "1", features = ["full"] }
tokio-tungstenite = "0.21"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
reqwest = { version = "0.11", features = ["json"] }
cpal = "0.15"
enigo = "0.2"
rodio = "0.17"
dirs = "5"
```

## Tauriプラグイン（公式）
| 用途 | プラグイン |
|------|-----------|
| グローバルショートカット | `@tauri-apps/plugin-global-shortcut` |
| クリップボード | `@tauri-apps/plugin-clipboard-manager` |
| 通知 | `@tauri-apps/plugin-notification` |
| 自動起動 | `@tauri-apps/plugin-autostart` |

## 権限（capabilities）
Tauri v2のプラグインは権限設定が必須。`src-tauri/capabilities/default.json` に以下を追加する。
- `global-shortcut:allow-register`
- `global-shortcut:allow-unregister`
- `global-shortcut:allow-is-registered`
- `clipboard-manager:allow-write-text`
- `notification:allow-notify`
- `notification:allow-is-permission-granted`
- `notification:allow-request-permission`
- `autostart:allow-enable`
- `autostart:allow-disable`
- `autostart:allow-is-enabled`

---

## テスト計画（最小）
- 手動テスト: 30秒の発話×5回
- 技術用語例文テスト（React/useState/TypeScript等）
- ネットワーク遮断時のエラーハンドリング確認
- マイク権限なし時の動作確認
- 30分連続利用テスト

---

## リスクと対策

| リスク | 対策 |
|--------|------|
| **ショートカット競合** | 初期値はOption+Space、設定で変更可能にする |
| **レイテンシ超過** | 送信バッファサイズ調整、LLM入力短縮 |
| **精度不足** | プロンプト調整、Deepgramの言語設定最適化 |
| **APIコスト増** | LLM呼び出しは録音終了時のみ（ストリーミング中は呼ばない） |
| **サンプルレート不一致** | デバイス既定値を取得してDeepgramへ指定 |
| **自動ペーストが一部アプリで不安定** | 設定で自動ペーストON/OFF切替を追加 |

---

## 次のアクション
1. Tauri v2プロジェクト初期化
2. メニューバーアプリの基本構造作成
3. グローバルショートカット（Option+Space）の実装
4. Linear16 PCM録音の最小PoC
5. Deepgram WebSocket接続の検証
