# engineer-agent

Webエンジニア・AIエンジニア特化の人材紹介事業の業務システム（集客・法人開拓・事務の自動化）。

## まず読むもの
1. [CLAUDE.md](CLAUDE.md) — 開発ルールと絶対ルール（AIエージェントも人も必読）
2. [docs/business-rules.md](docs/business-rules.md) — 事業・法務ルール
3. [docs/architecture.md](docs/architecture.md) — 全体設計とスプリント計画
4. [docs/specs/](docs/specs/) — スプリントごとの仕様書

## 現在の状態
- [x] DBスキーマ（`supabase/migrations/20261126000000_init.sql`）
- [x] S1・S2の仕様書
- [ ] S1 の実装（Next.js の初期化から）

## はじめ方
```bash
cp .env.example .env.local
supabase start
supabase db reset
```
そのうえで Claude Code / Codex に次のように依頼する：

> docs/specs/S1-foundation.md を実装して。CLAUDE.md のルールに従い、タスクごとにコミットして。
