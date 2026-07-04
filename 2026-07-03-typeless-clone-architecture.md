# システム設計書: AI音声入力アプリ macOS MVP

作成日: 2026-07-03
バージョン: 0.1

## 1. 技術スタック選定

### 1.1 クライアント: Swift/SwiftUI ネイティブ(第一候補)

理由:
- テキスト挿入(AXUIElement)、CGEventによるキーシミュレーション、NSWorkspaceによるフロントアプリ検出、グローバルホットキー(Carbon RegisterEventHotKey / NSEvent global monitor)はすべてネイティブAPIであり、ここの信頼性が製品の生死を分ける
- AVAudioEngineで低遅延録音、メニューバー常駐(MenuBarExtra)、省リソース
- Superwhisper / VoiceInk / Voibe など成功例はすべてネイティブ。VoiceInk(GPL、GitHub公開)が実装リファレンスとして利用可能

代替案: Tauri v2(Rust+React/TS)
Kyoheiの既存スタック(React/TS)を活かせるが、挿入・ホットキー・権限まわりでRustネイティブプラグインを結局書くことになる。UIが薄いメニューバーアプリではReact資産の効果が小さいため、SwiftUIを推奨。ただしSwiftに投資したくない場合はTauriでも成立する(挿入層はRustでCGEvent/AXを叩く)。

### 1.2 サーバー: 薄いプロキシ(Supabase Edge Functions または Hono on Cloudflare Workers)

役割はAPIキー秘匿・認証・使用量メータリング・レート制限のみ。音声/テキストは保存しない(パススルー)。KyoheiのSupabase経験を活かし、Auth+Postgres(ユーザー/サブスク/使用量)+Edge Functionsで構成。課金はStripe。

### 1.3 外部API

- STT: ElevenLabs Scribe v2 Realtime(日本語第一候補)/ Deepgram Flux(コスト・EOT検出)。プロバイダ抽象化インターフェースで差し替え可能に
- LLM整形: Claude Haiku 4.5(claude-haiku-4-5)ストリーミング。整形強度「しっかり」時のみSonnetへ昇格するルーティング

## 2. 全体構成図

```
┌─────────────────────────── macOS Client (Swift) ───────────────────────────┐
│                                                                              │
│  HotkeyManager ──▶ AudioCapture ──▶ STTStream ──┐                            │
│  (global hotkey)   (AVAudioEngine,  (WebSocket,  │                            │
│                     16kHz PCM)      partial結果) ▼                            │
│                                          TranscriptBuffer                    │
│  ContextCollector ───────────────────────────┐   │                            │
│  (frontmost app, 選択テキスト,               ▼   ▼                            │
│   フィールド直前テキスト via AX)          Formatter (LLM整形, streaming)      │
│                                               │                              │
│  HUD (フローティング表示: 波形/部分結果/整形中) │                              │
│                                               ▼                              │
│                                        TextInserter                          │
│                                        1) AX直接挿入                         │
│                                        2) fallback: clipboard+Cmd+V           │
│                                               │                              │
│  HistoryStore (SQLite/GRDB, ローカルのみ) ◀───┘                              │
│  DictionaryStore / SettingsStore                                             │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTPS/WSS (認証JWT)
                    ┌───────────▼───────────┐
                    │  Proxy (Supabase Edge  │──▶ STT Provider (ElevenLabs/Deepgram)
                    │  Fn / CF Workers)      │──▶ LLM (Anthropic API)
                    │  auth, metering,       │
                    │  rate limit, no store  │
                    └───────────┬───────────┘
                    ┌───────────▼───────────┐
                    │ Supabase (Auth,        │◀── Stripe Webhook
                    │ users, subscriptions,  │
                    │ usage_minutes)         │
                    └───────────────────────┘
```

## 3. クライアント モジュール設計

### 3.1 HotkeyManager

- CGEventTap(要アクセシビリティ権限)でFnキー長押し検出、またはRegisterEventHotKeyで修飾キー組み合わせ
- モード: push-to-talk(押している間)/ toggle(押して開始、再押下で終了)/ hands-free(VADで自動終了)
- 押下→録音開始まで200ms以内。AVAudioEngineは事前warm-up(prepare済みで待機)

### 3.2 AudioCapture

- AVAudioEngine inputNode、16kHz/16bit mono PCMへダウンサンプリング
- 100msチャンクでSTTStreamへ供給。ローカルにもリングバッファ保持(ネットワーク断リカバリ用)
- 簡易VAD(音量閾値+無音1.2秒)で発話終了候補を検出(Deepgram Flux利用時はサーバーEOTを優先)

### 3.3 STTStream(プロバイダ抽象化)

```swift
protocol STTProvider {
    func startStream(config: STTConfig) async throws
    func send(_ pcm: Data)
    var partials: AsyncStream<Transcript> { get }   // 部分結果
    var finals: AsyncStream<Transcript> { get }     // 確定セグメント
    func finish() async throws
}
```

- 実装: ElevenLabsScribeProvider / DeepgramFluxProvider / (将来) WhisperLocalProvider
- パーソナル辞書はkeyword boost / keyterm promptとして接続時に注入

### 3.4 ContextCollector

- NSWorkspace.shared.frontmostApplication → bundle IDでトーンプロファイル解決
- AXUIElementでフォーカス要素の kAXSelectedTextAttribute(Ask機能用)、kAXValue の末尾200文字(文脈接続用)を取得
- 取得失敗は許容(コンテキストなしで整形続行)

### 3.5 Formatter(LLM整形)

- 確定セグメントを文単位でLLMへストリーミング整形し、確定した文から順次挿入する「逐次コミット」方式(体感レイテンシ最小化)
- MVPでは簡略化し「発話終了→全文一括整形→一括挿入」でも可(P50 1.5秒目標を満たせるか計測して判断)
- プロンプト構成:

```
system:
  あなたは音声入力の整形エンジン。話し言葉の文字起こしを、
  意図を一切変えずに書き言葉へ整形する。
  ルール: フィラー除去 / 言い直しは最終意図のみ残す / 繰り返し圧縮 /
  句読点・改行付与 / 指定文体(#{style}) / 内容の追加・要約・回答は禁止
  辞書: #{user_dictionary}
  文脈(挿入先の直前テキスト): #{preceding_text}
  アプリ: #{app_profile}(トーン: #{tone})
  出力は整形後テキストのみ。
user:
  #{raw_transcript}
```

- 整形強度: off(生テキスト)/ light(フィラー・句読点のみ)/ full(言い直し統合・構造化まで)
- ガードレール: 出力が入力の1.5倍超/0.3倍未満の長さなら生テキストにフォールバックし警告表示(過剰書き換え防止)

### 3.6 TextInserter

1. AX直接挿入: フォーカス要素の kAXSelectedTextAttribute に整形テキストをset(カーソル位置に挿入される)。成功判定はsetの戻り値+値の再読で検証
2. フォールバック: NSPasteboard退避 → 整形テキストをセット → CGEventでCmd+V → 300ms後に退避内容を復元
3. 両方失敗: クリップボードに残し、HUDに「⌘Vで貼り付けてください」を表示
- Electron製アプリ、セキュアフィールド、ターミナル系での挙動をテストマトリクスで管理(Slack / Notion / Chrome / VS Code / Cursor / iTerm / Mail / Pages)

### 3.7 HUD

- NSPanel(nonactivating, floating level)。録音中は波形+部分文字起こし、整形中はスピナー、完了でフェードアウト
- フォーカスを奪わないこと(挿入先のフォーカス維持が絶対条件)

### 3.8 永続化

- SQLite(GRDB): history / dictionary / app_profiles / settings。すべてローカル、iCloud同期はP2
- Keychain: 認証トークン、BYOKキー

## 4. サーバー設計

### 4.1 エンドポイント

| パス | 役割 |
|---|---|
| POST /v1/auth/* | Supabase Auth委譲(email magic link + Google) |
| WSS /v1/stt | STTプロバイダへのWebSocketプロキシ。JWT検証、分単位メータリング |
| POST /v1/format (SSE) | LLM整形プロキシ。トークンメータリング |
| POST /v1/stripe/webhook | サブスク状態更新 |
| GET /v1/me/usage | 残量表示用 |

### 4.2 データモデル(Supabase Postgres)

```sql
users(id, email, created_at)
subscriptions(user_id, plan, status, stripe_customer_id, current_period_end)
usage_monthly(user_id, month, stt_seconds, llm_tokens)  -- 集計のみ、本文なし
devices(user_id, device_id, platform, last_seen)
```

音声データ・文字起こし本文はいかなるテーブルにも保存しない。ログにも本文を出さない(構造化ログでフィールド除外)。

### 4.3 メータリング/制限

- 無料: 月60分(stt_seconds基準)。超過時はクライアントに402返却、アップグレード導線
- Pro: 実質無制限(公正利用上限 月3,000分)
- レート制限: 同時ストリーム1本/デバイス、10リクエスト/分

## 5. レイテンシ予算(発話終了→挿入完了 目標P50 1.5s)

| 区間 | 予算 |
|---|---|
| EOT検出(VAD/Flux) | 300ms |
| STT最終セグメント確定 | 200ms |
| LLM整形 TTFT | 400ms |
| LLM整形 完了(80語) | 400ms |
| 挿入+検証 | 100ms |
| 合計 | 1.4s |

逐次コミット方式に移行すれば体感はさらに短縮(話し終わる前に前半が挿入済み)。

## 6. セキュリティ/プライバシー設計

- STT/LLMともゼロデータリテンション設定(ElevenLabs zero retention mode、Anthropic APIはデフォルトで学習不使用)を利用し、DPAを締結
- クライアント→プロキシはTLS+短寿命JWT。BYOKモード(P1)ではプロキシを経由せず直接プロバイダへ
- プライバシーポリシーに「音声・本文の保存ゼロ / 学習不使用 / 履歴は端末内」を明記(Typelessと同じ訴求を事実で担保)

## 7. iOS版 設計方針(次フェーズ、概要のみ)

- 構成: メインアプリ(録音・STT・整形・履歴)+カスタムキーボード拡張(挿入UI)
- キーボード拡張はマイク・メモリ制約が厳しいため、拡張は「マイクボタン→App Groups経由でメインアプリ/サーバーに処理依頼→結果を受けてinsertText」のリレー構成
- 代替UX: 共有シート/ショートカット起動のディクテーションシート
- パイプライン(STTStream/Formatter/Dictionary)はSwift Packageとして切り出し、macOSと共有する。これがmacOSをSwiftで書く追加の理由

## 8. Web版 設計方針(次フェーズ、概要のみ)

- 位置づけ: LP埋め込みプレイグラウンド+ブラウザ内テキストエリア用途
- スタック: Kyoheiの標準構成(Vite + React + TS + Tailwind + shadcn + Zustand + Supabase)
- MediaRecorder/AudioWorklet → WSS /v1/stt → SSE /v1/format → エディタ表示+コピー
- サーバーはmacOS版と完全共有(プロキシの汎用性検証にもなる)

## 9. テスト戦略

- 挿入テストマトリクス: 主要12アプリ×(AX挿入/ペースト)を毎リリース手動+可能な範囲でXCUITest化
- STT品質: 自前録音の日本語テストセット(50発話、専門用語込み)でWER/整形品質を回帰測定
- 整形品質: golden set(生テキスト→期待整形)50件のLLM評価をCIに組み込み
- 権限剥奪・ネットワーク断・クリップボード競合の異常系
