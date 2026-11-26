# S1：基盤（第1〜2週）

## ゴール
- 代表がログインし、候補者・企業・求人・選考を**手で**登録・更新できる。
- 承認待ちキュー画面がある（この時点では空でよい）。
- 以降のスプリントで使う共通ライブラリ（LLM、PIIマスク、Supabaseクライアント）が揃っている。

## スコープ外
- 外部送信（メール・LINE）、LLMによる生成処理、公開サイト → S2以降

---

## タスク

### 1. プロジェクトの初期化
- `npx create-next-app@latest . --ts --app --eslint --src-dir --import-alias "@/*"`（Tailwind 使用）
- UI：shadcn/ui
- 追加パッケージ：`@supabase/supabase-js` `@supabase/ssr` `zod` `@anthropic-ai/sdk` `vitest`
- `supabase init` → 既存の `supabase/migrations/` をそのまま使う
- `.env.example` を元に `.env.local` を作成（コミットしない）

### 2. 認証
- Supabase Auth（メールのマジックリンク、または Google ログイン）
- `/admin/**` は `staff` テーブルに存在するユーザーのみアクセス可能（middleware でチェック）
- 新規サインアップは無効化する。staff は SQL かシードで追加する

### 3. 管理画面（`/admin`）
| パス | 内容 |
|---|---|
| `/admin` | ダッシュボード（今日のネクストアクション、承認待ち件数、選考中の件数） |
| `/admin/candidates` | 一覧（ステータス・セグメント・温度感でフィルタ）／詳細／新規登録 |
| `/admin/companies` | 一覧（契約状態・スコア）／詳細（担当者・求人・シグナル・やり取り） |
| `/admin/jobs` | 一覧／詳細／新規登録（この時点では手入力） |
| `/admin/pipeline` | 選考のカンバン（列 = `application_stage`）。ドラッグでステージ変更 |
| `/admin/queue` | 承認待ちキュー（`v_approval_queue`）。承認・修正・却下 |

- 候補者詳細でPII（メール・電話）を表示したときは `audit_logs` に `view_pii` を記録する。
- 一覧は Server Components で取得し、更新は Server Actions で行う。

### 4. 共通ライブラリ
| ファイル | 内容 |
|---|---|
| `src/lib/supabase/server.ts` / `client.ts` / `admin.ts` | クライアント生成。`admin.ts`（service_role）はサーバー専用で、`import 'server-only'` を付ける |
| `src/lib/pii/mask.ts` | メール・電話番号・URL内のユーザー名・氏名（既知の値）をプレースホルダに置換する。**テスト必須** |
| `src/lib/llm/client.ts` | Claude API のラッパー。入力に未マスクのPIIらしき文字列（メール・電話番号の正規表現）があれば例外を投げる。モデル名は環境変数で切り替える |
| `src/lib/llm/structured.ts` | Zodスキーマを渡すと、tool use で構造化出力を受け取り検証するヘルパー |
| `src/domain/fee.ts` | 手数料額と返金期限・返金額の計算。**テスト必須** |

### 5. 型生成
- `supabase gen types typescript --local > src/lib/supabase/types.ts`
- `npm run db:types` スクリプトとして登録する

---

## 受け入れ条件
- [ ] staff 以外のユーザーは `/admin` にアクセスできない
- [ ] 候補者・企業・求人・選考を登録・編集できる
- [ ] カンバンでステージを変えると `application_stage_events` に記録される
- [ ] `mask.ts` と `fee.ts` のテストが通る
- [ ] `llm/client.ts` にメールアドレスを含む文字列を渡すと例外になる（テストあり）
- [ ] `npm run lint` と `npm run test` が通る

## `fee.ts` の仕様
```ts
calcFee(theoreticalAnnualSalary: number, feeRate: number): number
// 円未満は切り捨て。例: calcFee(8_000_000, 0.35) === 2_800_000

calcRefundDeadline(joinDate: Date, policy: RefundPolicy): Date
// policy の within_days の最大値を joinDate に加えた日

calcRefund(feeAmount: number, joinDate: Date, resignedAt: Date, policy: RefundPolicy): number
// 退職日までの日数が within_days 以内の最初の段階の rate を適用。該当がなければ 0
// policy の例: [{ within_days: 30, rate: 0.8 }, { within_days: 90, rate: 0.5 }]
```
