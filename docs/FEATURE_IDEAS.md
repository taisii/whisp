# 機能追加候補

競合アプリ（Aqua Voice、Superwhisper、VoiceInk、Willow Voice など）の調査に基づく機能アイデア一覧。

---

## 優先度：高

### カスタム辞書機能
- 頻繁に使用する単語や誤認識されやすい言葉を事前に登録
- 専門用語、人名、製品名などを正確に認識させる
- 参考: Aqua Voice（無料5件、有料800件）、VoiceInk（パーソナル辞書）

### ディクテーションモード切り替え
- 用途に応じたモードを選択可能にする
  - **標準モード**: 通常のテキスト入力
  - **ノートモード**: 箇条書き・キーポイント形式で出力
  - **コードモード**: プログラミング向け（変数名、関数名を正しく認識）
- 参考: Superwhisper（Super Mode、Note Mode、Custom Mode）

### 録音履歴の管理
- 過去の音声入力結果を一覧表示・検索可能に
- 履歴から再利用（クリップボードにコピー等）
- 不要な履歴の削除機能

---

## 優先度：中

### ショートカットフレーズ（テキスト展開）
- 短いフレーズで定型文を入力
- 例: 「マイアドレス」→ 自分の住所、「シグネチャ」→ メール署名
- 参考: Aqua Voice

### 翻訳機能
- 日本語音声 → 英語テキスト（またはその逆）の直接変換
- 多言語間のリアルタイム翻訳
- 参考: Whisper、MurmurType

### スクリーンショットモード（Vision LLM コンテキスト）

録音中にスクリーンショットを取得し、Vision LLM（Gemini Vision等）で画面の状況を解析してコンテキストとして利用する機能。

#### ユースケース
- コードエディタで図やUIを見ながら説明する場合
- ブラウザで参照しているドキュメントの内容を踏まえた入力
- 画像編集ソフトでの作業内容に応じた指示
- テキストが選択できないアプリケーションでの利用

#### 実装案

**トリガー**
- 設定で有効化（デフォルトOFF）
- 録音開始時にスクリーンショットを取得

**処理フロー**
1. 録音開始時にスクリーンショット取得（macOS: `CGWindowListCreateImage`）
2. 録音中に非同期で Vision LLM に送信
3. 「画面の状況説明」を取得
4. STT完了後、状況説明をコンテキストとして post_processor に渡す

**Vision LLM プロンプト例**
```
この画面のスクリーンショットを見て、ユーザーが何をしているか簡潔に説明してください。
- アクティブなアプリケーション
- 表示されているコンテンツの概要
- ユーザーが作業中と思われるタスク
```

#### 考慮事項

**レイテンシ**
- 録音中に並行処理することで、STT完了時には状況説明が準備済みになる
- 目標: STT完了後の追加レイテンシ 0ms

**プライバシー**
- スクリーンショットは外部APIに送信される
- 機密情報が映る可能性がある
- 設定で明示的に有効化が必要
- 送信前に確認ダイアログを表示するオプション

**コスト**
- Vision API は通常のテキスト API より高コスト
- 使用頻度に応じた課金増加

#### 必要な権限
- Screen Recording（画面収録）権限

#### 関連設定項目
```toml
[vision]
enabled = false
capture_on_recording = true
confirm_before_send = false
```

---

## 優先度：低（将来的な検討）

### ローカル処理オプション
- プライバシー重視ユーザー向けにオフラインでの音声認識
- Whisperモデルをローカルで実行
- 参考: Superwhisper、VoiceInk、MacWhisper

### マルチスピーカー認識
- 複数人の会話を話者ごとに区別して文字起こし
- 会議やインタビューの議事録作成向け
- 参考: Spokenly

### ファイル文字起こしの強化
- 音声/動画ファイルのドラッグ＆ドロップ対応
- バッチ処理（複数ファイルの一括文字起こし）
- 参考: Superwhisper、MacWhisper

### マウスアクティベーション
- ホットキーだけでなくマウス操作でも録音開始可能に
- メニューバーアイコンのクリックで録音トグル
- 参考: Superwhisper

---

## 調査参考リンク

- [Aqua Voice 徹底解説](https://aisokuho.com/2025/10/04/a-thorough-explanation-of-aqua-voice-the-ai-tool-that-takes-voice-input-to-the-next-level/)
- [Superwhisper Custom Mode](https://superwhisper.com/docs/modes/custom)
- [VoiceInk レビュー](https://note.com/dubhunter/n/n4c9136eaab10)
- [音声入力アプリ比較](https://zenn.dev/ran_21050/articles/345589d8a1b77f)
- [Best dictation software for Mac 2025](https://setapp.com/how-to/best-dictation-software-for-mac)
