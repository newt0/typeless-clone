# オーナーがやること（2026-07-05 時点）

Claude はコードを自律開発・自己マージします。ここに並ぶのは **Claude が実行できず、あなたにしかできない作業だけ**です。優先度順。

> 🔐 セキュリティ: APIキーや `security` コマンドは **このチャットに貼らず、自分のターミナルで**実行してください。キーがチャット履歴に残るのを避けるためです。

---

## ✅ 完了済み（対応不要）

- Xcode 26.6 インストール / `xcode-select`
- `gh auth login`
- Bundle ID 決定（`dev.newt.Koe`、恒久）
- **Gemini + Speechmatics APIキーを Keychain に登録・検証済み** → M4/M6 と垂直スライスのブロック解除済み

---

## 🟡 いますぐ（任意・M4 のライブ疎通確認）

Speechmatics STT アダプタ（M4）が入りました。実 API との疎通を確認したい場合のみ:

1. **16kHz / モノラル / PCM16 の日本語 WAV を1つ用意**
   - QuickTime 等で数秒しゃべって録音 → 変換:
     ```
     afconvert -f WAVE -d LEI16@16000 -c 1 入力.m4a サンプル.wav
     ```
2. **自分のターミナルで**ライブテストを実行:
   ```
   KOE_STT_SAMPLE_WAV=/path/to/サンプル.wav KOE_LIVE_TESTS=1 ./scripts/test.sh
   ```
3. `SpeechmaticsClient integration` の出力に **partial が1つ以上・final の日本語文字列**が出れば疎通OK。
4. 結果を PR #12 か #13 にコメントで貼付（CI は keyless 方針なので手元結果が唯一の記録）。

> やらなくても CI もデフォルトのテストも green のまま。急ぎません。

---

## 🟠 近いうち（次のマイルストーンの実機QAで必要）

次は M2（ホットキー）→ M3（マイク音声）→ 垂直スライスに進みます。ここは **実機で権限ダイアログを承認する**あなたの操作が必須です。

- **アプリを起動して権限を許可**（Claude が実装後に依頼します）:

  ```
  brew install xcodegen        # 未導入なら一度だけ
  xcodegen generate            # project.yml 変更後に再生成
  open Koe.xcodeproj           # Xcode で Run、または built Koe.app を open
  ```

  - **マイク**（M3）と **アクセシビリティ**（M2 ホットキー / M5 貼り付け）の許可ダイアログで「許可」。
  - ※ Input Monitoring は要求しません（設計方針）。

- 各マイルストーン完了時、Claude が **日本語のQAチェックリスト**を提示します（実際にしゃべって挿入されるか等）。それを実施して合否を返す。

---

## ⚪ あとで（Phase 0 の比較評価・急がない）

- **S2 発話録音**（STT の A/B 用、約100クリップ）: 必要になったら Claude が録音スクリプト（読み上げ文リスト）を提示します。
- **Phase 0 A/B 用の追加キー**: Deepgram / Soniox / AWS Bedrock（東京）。STT/LLM の正式比較をする段階で。

---

## 🚨 Claude が必ずあなたに確認する事項（覚えておくだけでOK）

Claude は以下だけエスカレーションします。それ以外は自分で判断して `docs/decisions.md` に記録し進めます:

- お金 / アカウント / 利用規約に関わること
- 新しい第三者へのデータ送信先の追加
- フェーズゲートの No-Go 判定
- 恒久的な識別子（Bundle ID / 署名 ID）
- 破壊的・不可逆な操作

> 補足: Speechmatics の ToS §10.3（保存/学習ライセンス条項の矛盾）は、Phase 1 の個人ドッグフードでは許容と設計済み。**ベータ配布前に**書面で要確認、という既知リスクとして記録済みです。

---

進捗の唯一の真実は `docs/plan/STATUS.md`。困ったら Claude に「STATUS 教えて」と聞けば現在地を返します。
