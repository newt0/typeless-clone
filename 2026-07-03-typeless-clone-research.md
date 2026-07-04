# TYPELESS クローン開発 調査レポート

作成日: 2026-07-03
作成者: 伊藤匡平 / Claude

## 1. TYPELESS とは

Typeless は「話すだけで、丁寧にタイプしたような文章になる」AI 音声入力(ボイスキーボード)。生の文字起こしではなく、LLM による整形を挟むのが本質。公称 220wpm(タイピングの約4倍)、週1日分の時間節約を訴求。macOS / Windows / iOS / Android 対応で、カーソルがあるあらゆるアプリに直接テキストを挿入する。

### 1.1 機能分解(公式サイトより)

| カテゴリ | 機能 | 実装上の本質 |
|---|---|---|
| Dictate | フィラー除去(えー、あの、um) | LLM後処理 |
| Dictate | 繰り返し・冗長表現の除去 | LLM後処理 |
| Dictate | 言い直しの自動編集(最終意図のみ残す) | LLM後処理(これが差別化の核) |
| Dictate | 自動フォーマット(箇条書き・手順の構造化) | LLM後処理 |
| Dictate | パーソナライズ(口調・文体学習) | ユーザープロファイル+few-shot |
| Dictate | パーソナル辞書(固有名詞・専門用語) | STTのkeyword boost + LLMプロンプト注入 |
| Dictate | 100+言語、混在発話の自動検出 | STTモデル依存 |
| Dictate | アプリごとのトーン切替(Slackはカジュアル、メールはフォーマル) | アクティブアプリ検出+プロンプト分岐 |
| Translate | 話しながら翻訳 | LLM後処理の変種 |
| Ask anything | 選択テキストへの音声コマンド編集 | Accessibility APIで選択テキスト取得+LLM |
| Ask anything | 選択テキストへの質問(要約・説明・翻訳) | 同上 |
| Ask anything | クイック回答・アクション(検索、ページ起動) | エージェント機能 |
| Privacy | クラウドゼロ保持、学習不使用、履歴はローカル保存 | アーキテクチャ設計方針 |

### 1.2 アーキテクチャの本質

TYPELESS 系プロダクトのパイプラインは全て以下に収束する。

```
グローバルホットキー押下
→ マイク録音(ストリーミング)
→ STT(クラウドまたはローカル)
→ コンテキスト取得(アクティブアプリ、選択テキスト、直前テキスト)
→ LLM整形(フィラー除去・言い直し統合・トーン適応・辞書適用)
→ カーソル位置へテキスト挿入(Accessibility API / ペーストシミュレーション)
```

差別化はSTT精度ではなく「LLM整形プロンプトの質」「コンテキスト取得の深さ」「挿入の信頼性」「レイテンシ」の4点。

## 2. 競合ランドスケープ

| プロダクト | 方式 | 価格 | 特徴 |
|---|---|---|---|
| Typeless | クラウド | サブスク | 整形品質・パーソナライズ・4OS対応 |
| Wispr Flow | クラウド | $15/月(無料2,000語/週) | 最も洗練されたUX。Mac/Win/iOS/Android。SOC2 Type II、HIPAA対応 |
| Superwhisper | ローカル(Whisper) | $8.49/月 or $249.99買い切り | プライバシー特化、Mac/iOSのみ、モード機構、設定は複雑 |
| VoiceInk | ローカル、OSS | $29〜買い切り | オープンソース。実装の参考に最適 |
| Voibe | ローカル | $149買い切り | Live Dictation(挿入前に画面上で編集可) |
| MacWhisper | ローカル | €59買い切り | ファイル文字起こし主体、リアルタイムは弱い |
| Spokenly | ローカル+BYOK | 無料 | ローカルParakeet/Whisper無制限、BYOKでクラウド |
| Aqua Voice / Willow | クラウド | サブスク | ブラウザ寄り・単一OS寄り |

市場の教訓: クラウド型はUX・整形品質で勝ち、ローカル型は価格・プライバシーで勝つ。無料枠(Wispr: 2,000語/週)がオンボーディングの標準。Wispr Flowはカスタマーサポートへの不満がRedditで多く、日本語特化+丁寧なサポートは差別化余地がある。

### 2.1 日本語市場の空白

上記はいずれも英語ファースト。日本語特有の課題(敬語レベルの切替、口語→文語変換、「ですます」「である」統一、話し言葉の助詞落ち補完)を深く作り込んだ製品は事実上存在しない。日本語ネイティブの整形品質が最大の参入角度になる。

## 3. 技術コンポーネント調査

### 3.1 STT API 比較(2026年6月時点)

| プロバイダ | モデル | 方式 | 料金目安 | 日本語 | 備考 |
|---|---|---|---|---|---|
| Deepgram | Nova-3 / Flux | ストリーミング | $0.0077/分(streaming)、$0.0043/分(batch) | 対応 | 最安クラス。Fluxは発話終了検出内蔵、EOT<300ms |
| ElevenLabs | Scribe v2 Realtime | ストリーミング | $0.39/時(≒$0.0065/分) | 強い(FLEURS日本語WER 3.1%を公称) | <150ms初期レイテンシ、90+言語自動検出 |
| OpenAI | gpt-4o-transcribe / mini | ストリーミング | 約$0.006/分 | 対応 | GPT-4o級精度 |
| OpenAI | GPT-Realtime-Whisper | ストリーミング | $0.017/分 | 対応 | 低遅延特化、やや高い |
| OpenAI | Whisper large-v3 (OSS) | バッチ/ローカル | 無料(自前GPU) | 対応 | ローカル版・オフライン対応の基盤 |
| NVIDIA | Parakeet V3 | ローカル | 無料 | 25言語 | Apple Siliconで高速。MacWhisper採用実績 |
| Apple | Speech / SFSpeechRecognizer | ローカル | 無料 | 対応 | iOSキーボード制約下の逃げ道 |

推奨: MVPは ElevenLabs Scribe v2 Realtime(日本語精度)または Deepgram Flux(コスト+EOT検出)の2択でA/Bして決定。BYOK対応にしておくと乗り換え耐性がつく。

### 3.2 LLM整形レイヤー

1回の発話(平均15秒、約80語)の整形は入力500トークン+出力150トークン程度。Claude Haiku 4.5 クラスの小型高速モデルで十分であり、1発話あたり0.1円未満。ストリーミング整形(文単位で確定させて逐次挿入)がレイテンシ体感の鍵。

### 3.3 プラットフォーム別のテキスト挿入技術

macOS:
- Accessibility API(AXUIElement)でフォーカス要素へ直接挿入、または選択テキスト取得
- フォールバック: クリップボード退避 → CGEventでCmd+Vシミュレーション → クリップボード復元
- 必要権限: マイク、アクセシビリティ(入力監視)。App Store配布は制約が強いためDeveloper ID+notarizationの直接配布が業界標準(Wispr/Superwhisper/Voibeすべて直接配布)
- アクティブアプリ検出: NSWorkspace.frontmostApplication → アプリ別トーン切替に利用

Windows(将来):
- UI Automation + SendInput。Electron/Tauriなら同一コードベースで対応可能

iOS:
- カスタムキーボード拡張(Keyboard Extension)が必須だが、拡張内のマイク利用はFull Access許可+実装制約が多く、メモリ上限(約60〜70MB)も厳しい
- 現実解: キーボード拡張は「挿入とUI」に徹し、録音・STT・整形は App Groups 経由でメインアプリまたはサーバーに委譲する構成。もしくはメインアプリ内ディクテーション+共有シートから開始
- 開発難度は3プラットフォーム中最高

Web:
- MediaRecorder / AudioWorklet + WebSocketストリーミングSTTで「デモ・トライアル」は完全に作れる
- ただし他アプリへの挿入は原理的に不可能(コピー用途のみ)。製品価値の核である「どこでも書ける」は実現できない
- 位置づけはマーケティング/オンボーディング用のプレイグラウンド

## 4. 作りやすさ×価値のマトリクス

| プラットフォーム | 開発難度 | 製品価値 | 判定 |
|---|---|---|---|
| Web | 低 | 低(挿入不可、デモ止まり) | 2番手。LP用デモとして後日 |
| macOS メニューバーアプリ | 中 | 高(コア価値をフル実現) | 最初に作るべき本命 |
| iOS キーボード拡張 | 高 | 高 | Mac版でパイプライン検証後 |

結論: macOSメニューバーアプリをMVPとする。理由は (1) 「どこでも音声入力」というコア価値を最短で実証できる、(2) 競合が全てMacから始めている(市場の答え)、(3) STT+LLM整形パイプラインはそのままiOS/Webに転用できる、の3点。

実装スタックはSwift/SwiftUIネイティブを第一候補、Tauri v2(Rust+React/TS)を第二候補とする。詳細はアーキテクチャ設計書を参照。

## 5. コスト試算(クラウド型MVP)

ヘビーユーザー想定: 1日30分ディクテーション×30日=900分/月
- STT(Deepgram streaming): 900×$0.0077 ≒ $6.9/月
- LLM整形(小型モデル): 概算$1〜2/月
- 合計原価 約$8〜9/月/ヘビーユーザー → 月額1,980〜2,980円の価格設定で成立
- 無料枠は「週2,000語」または「月60分」相当でWispr Flowと同水準に

## 6. 参考リンク

- https://www.typeless.com/
- https://wisprflow.ai/ (競合、比較ページが充実)
- https://superwhisper.com/ (ローカル型の参考)
- https://github.com/Beingpax/VoiceInk (OSS実装の参考)
- https://github.com/sebsto/wispr (OSSのmacOSローカルディクテーション、Whisper/Parakeet両対応)
- https://elevenlabs.io/ja/speech-to-text (Scribe v2 Realtime)
- https://deepgram.com/ (Nova-3 / Flux)
