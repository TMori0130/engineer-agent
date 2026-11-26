# プロンプト設計の方針

実装は `src/lib/llm/prompts/<name>.ts`、設計意図はこのディレクトリの `<name>.md` に書く。

## 共通ルール
1. **入力はPIIをマスクしたものだけ**（`src/lib/pii/mask.ts` を通す）。
2. **出力は構造化する**：tool use と Zod で検証する。自由記述の本文も、`{ subject, body, rationale }` のようなオブジェクトで受け取る。
3. **`rationale`（なぜこの内容にしたか）を必ず出力させる**：承認キューで、承認者が短時間で判断できるようにするため。
4. **事実を捏造させない**：求人や企業に関する記述は、入力として渡した情報だけを根拠にするよう指示する。根拠がない項目は「不明」と出力させる。
5. **トーン**：エンジニアに向けた文章は、誇張・煽り・定型的な美辞麗句を避け、具体的な技術用語で書く。

## 作成予定のプロンプト

| 名前 | 用途 | スプリント | モデル |
|---|---|---|---|
| `article-outline` | キーワードから記事の構成案を作る | S3 | quality |
| `article-draft` | 構成案から本文の下書きを作る | S3 | quality |
| `company-outreach` | 企業シグナルから初回営業メールを作る | S4 | quality |
| `reply-classify` | 返信を interested / later / not_interested / unsubscribe に分類する | S4 | fast |
| `job-structure` | 求人票の原文を構造化する | S5 | fast |
| `resume-extract` | 職務経歴書からスキル・経験を抽出する | S5 | fast |
| `match-explain` | 候補者×求人のマッチ理由を説明する | S5 | quality |
| `recommendation-draft` | 推薦文の下書き | S5 | quality |
| `scout-draft` | スカウト媒体向けの個別文案 | S5 | quality |
| `meeting-summary` | 面談議事録の要約とネクストアクションの抽出 | S5 | quality |

## 例：`company-outreach` の出力スキーマ
```ts
z.object({
  subject: z.string().max(40),
  body: z.string().max(600),          // フッター（送信者情報・配信停止）はコード側で付与する
  hook: z.string(),                   // 何をきっかけに連絡したか（例：シリーズB調達のニュース）
  rationale: z.string(),              // 承認者向けの説明
  confidence: z.enum(['high', 'medium', 'low']), // low は承認キューで目立たせる
})
```
