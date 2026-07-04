# 開発計画書: macOS MVP ロードマップ + Claude Code 実装プロンプト

作成日: 2026-07-03

## 1. フェーズ計画(1人開発+Claude Code前提)

### Phase 0: 技術検証スパイク(3〜5日)

目的: 製品の生死を分ける3点を先に潰す。
1. AX挿入の信頼性検証: Slack / Notion / Chrome / VS Code / Cursor / iTerm / Mail で挿入成功率を計測する使い捨てCLIを作る
2. STT日本語ベンチ: 自分の声で50発話(SENQ、Avalanche、JasmyLab等の固有名詞込み)を録音し、ElevenLabs Scribe v2 / Deepgram Nova-3 / gpt-4o-transcribe のWERと体感レイテンシを比較
3. 整形プロンプト検証: 生文字起こし→整形のgolden set 30件を作り、Haiku 4.5で品質・レイテンシを確認

Go/No-Go基準: 挿入成功率95%以上(フォールバック込み99%)、日本語WER 8%未満、整形P50 1.5秒以内。

### Phase 1: コアループ(2週間)

ホットキー→録音→STT→整形→挿入の一本道を動かす。HUDは最小(録音インジケータのみ)。設定はローカルJSON直書きで可。この時点から自分で毎日使う(dogfooding)。

### Phase 2: プロダクト化(2〜3週間)

- HUD(波形+部分結果+整形中表示)、オンボーディング(権限誘導)、設定画面
- パーソナル辞書、整形強度3段階、文体設定(ですます/である)
- 履歴(SQLite)、メニューバーUI
- Sparkle自動更新、Developer ID署名+notarization、DMG配布

### Phase 3: クローズドβ(2週間)

- Supabaseプロキシ+Auth+メータリング接続(それまではBYOK直叩きで開発)
- SendAI Japanコミュニティ+X(開発KOLとしての発信力を活用)で20〜50人に配布
- 計測: 手直し率、挿入失敗アプリ、D7継続

### Phase 4: 公開+課金(2週間)

- Stripe課金、無料枠制御、LP(Web版プレイグラウンドはこのタイミングで簡易版を載せると転換率が上がる)
- Product Hunt / X ローンチ

合計: 約8〜10週間でパブリックβ。

## 2. マイルストーン別 完了条件

| M | 内容 | 完了条件 |
|---|---|---|
| M0 | スパイク | Go/No-Go基準クリア、STTプロバイダ決定 |
| M1 | コアループ | 自分の日常業務の文章作成50%を音声化できる |
| M2 | プロダクト化 | 家族・同僚が説明なしでセットアップ完了できる |
| M3 | β | 20人以上が週3回以上利用、手直し率40%未満 |
| M4 | 公開 | 課金導線が通り、初の有料ユーザー |

## 3. リポジトリ構成案

```
koe/
├── apps/
│   └── macos/            # Xcode project (SwiftUI menu bar app)
├── packages/
│   └── VoiceCore/        # Swift Package: STTProvider, Formatter, Dictionary
│                         #   (iOS版で再利用する共有層)
├── server/               # Supabase (edge functions, migrations)
│   ├── functions/stt-proxy/
│   ├── functions/format/
│   └── functions/stripe-webhook/
├── bench/                # WER・整形品質ベンチ (Python or TS)
│   ├── audio/            # テスト発話 (git-lfs)
│   └── golden/           # 整形golden set
└── docs/                 # 本設計書一式
```

## 4. Claude Code 用 plan-mode プロンプト(Phase 1 コアループ)

以下をそのままClaude Codeのplan modeに投入して使う想定。

```
# タスク: macOSメニューバー音声入力アプリ「Koe」のコアループ実装

## ゴール
グローバルホットキー → 録音 → ストリーミングSTT → LLM整形 → カーソル位置挿入
の一本道が動くSwiftUIメニューバーアプリを実装する。

## 技術制約
- Swift 5.10+ / SwiftUI / macOS 14+、Xcodeプロジェクト
- メニューバー常駐 (MenuBarExtra)、Dockアイコンなし (LSUIElement)
- 録音: AVAudioEngine、16kHz/16bit mono PCM、100msチャンク
- ホットキー: CGEventTapでFnキー長押し(push-to-talk)。
  アクセシビリティ権限が無い場合は権限誘導画面を表示
- STT: ElevenLabs Scribe v2 Realtime WebSocket
  (環境変数 ELEVENLABS_API_KEY、プロトコルは公式docs参照)。
  STTProvider protocolで抽象化し、DeepgramFluxProviderも
  スタブとして用意
- 整形: Anthropic Messages API streaming、model=claude-haiku-4-5
  (環境変数 ANTHROPIC_API_KEY)。
  systemプロンプトは docs/format-prompt.md を読み込む
- 挿入: 第一手段 AXUIElement kAXSelectedTextAttribute への set、
  失敗時 NSPasteboard退避 → CGEvent Cmd+V → 復元。
  両方失敗時はクリップボードに残して通知
- HUD: nonactivating NSPanel、録音中インジケータ+部分文字起こし表示。
  フォーカスを絶対に奪わないこと
- 履歴: GRDBでSQLiteに raw/formatted/app_bundle_id/created_at を保存

## 実装しないこと (今回スコープ外)
- 課金、認証、サーバープロキシ (APIキー直叩きでよい)
- 設定UI (定数とJSONでよい)
- 多言語UI

## 品質要件
- ホットキー押下から録音開始まで200ms以内 (AVAudioEngineをprepare済みで待機)
- 発話終了から挿入完了までP50 1.5秒をログで計測できるようにする
  (各区間のタイムスタンプをos_logに出す)
- 挿入失敗でもテキストを絶対に喪失しない

## 進め方
1. まずプロジェクト構成と各モジュールのprotocol定義を提示して合意を取る
2. HotkeyManager + AudioCapture + HUD (録音まで) を先に動かす
3. STTStream (ElevenLabs) を接続し部分結果をHUDに表示
4. Formatter + TextInserter を接続してエンドツーエンド
5. 履歴保存とエラーハンドリング
各ステップでビルドが通り手動確認できる状態を維持すること。
```

## 5. 整形プロンプト初版(docs/format-prompt.md 用)

```
あなたは日本語音声入力の整形エンジンです。話し言葉の文字起こしを、
話者の意図を一切変えずに、そのまま送信できる書き言葉へ整形します。

ルール:
1. フィラーを削除する(えー、あのー、なんか、まあ、um、uh など)
2. 言い直しは最終的な意図のみを残す
   例:「明日、あ、違う、明後日に送ります」→「明後日に送ります」
3. 同じ内容の繰り返しは1回に圧縮する
4. 句読点と改行を適切に付与する。列挙や手順は箇条書きに整形してよい
5. 文体は {{style}} に統一する(ですます / である / 原文維持)
6. 固有名詞は辞書を最優先する: {{dictionary}}
7. 内容の追加、要約、質問への回答、意見の挿入は禁止。整形のみを行う
8. 挿入先の直前テキストが与えられた場合、文が自然に接続するよう
   語尾と接続詞のみ調整してよい: {{preceding_text}}

出力は整形後のテキストのみ。説明や前置きは不要。
```

## 6. 次のアクション(今週)

1. STTベンチ用の自前音声50発話を録音する(スマホで可、固有名詞リストを先に作る)
2. Phase 0スパイクのGo/No-Go基準に合意する
3. プロダクト名を決める(「Koe」は仮。商標・ドメイン確認要)
4. ElevenLabs / Deepgram / Anthropic のAPIキーを開発用に発行
