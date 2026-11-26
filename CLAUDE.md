# CLAUDE.md

このリポジトリは、Webエンジニア・AIエンジニア特化の**有料職業紹介事業**の業務システムです。
運営は代表1名＋技術顧問（副業）。面談・推薦・入社サポートは人が行い、それ以外（集客・法人開拓・事務・法定対応）を自動化します。

AIコーディングエージェント（Claude Code / Codex）は、実装前に必ずこのファイルと `docs/business-rules.md` を読むこと。

---

## 絶対ルール（違反する実装をしてはいけない）

1. **外部送信は必ず人の承認を経る**
   - メール・LINE・スカウト・SNS投稿など、社外に届くものはすべて `outbound_messages`（または `content_articles`）を経由する。
   - `status = 'approved'` かつ `approved_at IS NOT NULL` のものだけを送信する。DBのCHECK制約でも担保している。
   - 「承認をスキップするオプション」「一括自動送信」を勝手に実装しない。
   - 例外：候補者が自分で操作した直後の**トランザクションメール**（診断結果の送付、登録完了通知など）は承認不要。`kind = 'transactional'` で区別する。

2. **個人情報（PII）の取り扱い**
   - 候補者の氏名・メール・電話番号・LINE ID・住所を **LLM API に送らない**。`src/lib/pii/mask.ts` でマスクしてから渡す。
   - 職務経歴書の解析など本文が必要な処理は、氏名・連絡先を除去したテキストを渡す。
   - PIIをログ（console.log、Sentryなど）に出力しない。
   - 全テーブルで RLS を有効にする。新しいテーブルを作るときも必ず RLS とポリシーを書く。
   - 同意（`consents`）のない候補者・リードには、トランザクションメール以外を送らない。

3. **特定電子メール法**
   - 営業メールには送信者名・住所・配信停止リンクを必ず入れる（`src/lib/mail/footer.ts`）。
   - `contacts.unsubscribed_at` / `leads.unsubscribed_at` がある宛先には送らない。

4. **職業安定法・指針**
   - 求職者に金銭・ギフト券などを提供して勧誘する機能（お祝い金、登録特典など）を実装しない。
   - 手数料・早期離職率など法定の情報公開・事業報告に使う数値は、`v_annual_report` などのビューから算出する。手入力の値を使わない。

5. **スクレイピング**
   - robots.txt と各サイトの利用規約を守る。ログインが必要なページ（LinkedIn、ビズリーチなど）をクロールしない。
   - スカウト媒体への自動送信は実装しない（文案の生成まで）。

---

## 技術スタック

- Next.js（App Router, TypeScript strict）+ Vercel
- Supabase（Postgres 16 + pgvector + Auth + Storage + RLS）
- バックグラウンドジョブ：Inngest（`src/jobs/`）
- LLM：Claude API（`@anthropic-ai/sdk`）。呼び出しは必ず `src/lib/llm/` 経由にする
- Embedding：Voyage AI（1024次元）。`src/lib/embedding/` 経由にする
- メール：Resend / LINE：Messaging API / 会計：freee API
- テスト：Vitest（単体）、Playwright（E2E）
- Lint/Format：ESLint + Prettier

## ディレクトリ構成

```
docs/
  business-rules.md      事業・法務ルール（必読）
  architecture.md        全体設計
  specs/                 スプリントごとの仕様書（実装はここを正とする）
  prompts/               LLMプロンプトの設計書
supabase/
  migrations/            DBマイグレーション（スキーマ変更は必ずここで行う）
  seed.sql               開発用ダミーデータ（実在の人物・企業を使わない）
src/
  app/                   Next.js（(public) = 公開サイト, admin = 管理画面, api = Webhook）
  lib/                   llm, embedding, pii, mail, line, supabase, freee
  jobs/                  Inngestジョブ
  domain/                ドメインロジック（スコアリング、手数料計算など。純粋関数にしてテストする）
```

## 開発ルール

- 実装の前に `docs/specs/` の該当仕様を読む。仕様にない挙動を追加するときは、まず仕様書を更新する。
- DBスキーマは Supabase の管理画面で直接変更しない。`supabase migration new <name>` で作成する。
- `src/domain/` の関数には必ず単体テストを書く（手数料計算・返金期限・スコアリングは特に）。
- LLM プロンプトはコードに直書きせず、`src/lib/llm/prompts/` に置き、`docs/prompts/` に設計意図を書く。
- LLM の出力は Zod でスキーマ検証する。検証に失敗したら人の確認キューに回す。
- 金額は整数（円）で扱う。浮動小数点を使わない。
- 日時は `timestamptz` で保存し、表示は Asia/Tokyo にする。
- 開発・テスト用データに実在の人物・企業の情報を使わない。

## コマンド

```bash
npm run dev          # 開発サーバー
npm run test         # Vitest
npm run lint
supabase start       # ローカルSupabase
supabase db reset    # マイグレーション＋seedを再適用
```
