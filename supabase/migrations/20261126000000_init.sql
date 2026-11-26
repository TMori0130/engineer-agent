-- =====================================================================
-- 初期スキーマ
-- 方針:
--   * 全テーブルで RLS を有効にする（staff のみアクセス可）
--   * 公開フォーム（診断ツールなど）は service_role を使うサーバー側の処理から書き込む
--   * 外部送信は outbound_messages を経由し、承認されたものだけを送信する（CHECK制約）
--   * 金額は bigint（円）
-- =====================================================================

create extension if not exists vector;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 列挙型
-- ---------------------------------------------------------------------
create type staff_role as enum ('admin', 'advisor');
create type segment as enum ('web', 'web_to_ai', 'ai_ml');
create type candidate_status as enum (
  'new',            -- 登録直後
  'nurturing',      -- 情報収集層（ナーチャリング中）
  'interview_set',  -- 面談設定済み
  'active',         -- 転職活動中（推薦対象）
  'placed',         -- 入社済み
  'on_hold',        -- 保留
  'closed'          -- 終了
);
create type consent_purpose as enum (
  'privacy_policy',      -- 個人情報の取扱い（必須）
  'job_introduction',    -- 職業紹介サービスの利用
  'marketing_email',     -- メールでの情報提供
  'marketing_line'       -- LINEでの情報提供
);
create type contract_status as enum ('prospect', 'contacted', 'negotiating', 'contracted', 'paused', 'lost');
create type job_status as enum ('draft', 'open', 'paused', 'closed');
create type remote_policy as enum ('full_remote', 'hybrid', 'onsite', 'unknown');
create type channel as enum ('email', 'line', 'scout', 'phone', 'meeting', 'sns');
create type message_kind as enum ('transactional', 'nurture', 'outreach');
create type message_status as enum ('draft', 'pending_approval', 'approved', 'sending', 'sent', 'failed', 'cancelled');
create type reply_class as enum ('interested', 'later', 'not_interested', 'unsubscribe', 'other');
create type application_stage as enum (
  'proposed',          -- 候補者に提案中
  'recommended',       -- 企業に推薦済み
  'document_screening',
  'interview_1',
  'interview_2',
  'final_interview',
  'offer',
  'accepted',          -- 内定承諾
  'joined',            -- 入社
  'rejected',
  'withdrawn'
);
create type article_status as enum ('idea', 'drafting', 'review', 'approved', 'published', 'archived');

-- ---------------------------------------------------------------------
-- 共通関数
-- ---------------------------------------------------------------------
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- スタッフ
-- ---------------------------------------------------------------------
create table staff (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null,
  role        staff_role not null default 'admin',
  created_at  timestamptz not null default now()
);

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where id = auth.uid());
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where id = auth.uid() and role = 'admin');
$$;

-- ---------------------------------------------------------------------
-- リード（診断ツール・LINE登録などの見込み層）
-- ---------------------------------------------------------------------
create table leads (
  id                      uuid primary key default gen_random_uuid(),
  email                   text,
  line_user_id            text unique,
  source                  text not null,              -- 'diagnosis' | 'line' | 'article' | 'event' ...
  utm                     jsonb not null default '{}',
  segment                 segment,
  diagnosis_input         jsonb,
  diagnosis_result        jsonb,
  engagement_score        int not null default 0,     -- 開封・クリック・診断利用から算出
  unsubscribed_at         timestamptz,
  converted_candidate_id  uuid,                       -- candidates 作成後に設定
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint leads_contact_required check (email is not null or line_user_id is not null)
);
create unique index leads_email_unique on leads (lower(email)) where email is not null;
create trigger leads_updated_at before update on leads for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- 候補者
-- ---------------------------------------------------------------------
create table candidates (
  id                  uuid primary key default gen_random_uuid(),
  -- PII（LLMに渡さない・advisorには見せない）
  full_name           text,
  email               text,
  phone               text,
  line_user_id        text unique,
  -- 非PII
  segment             segment,
  status              candidate_status not null default 'new',
  source              text not null,
  lead_id             uuid references leads (id),
  temperature_score   int not null default 0 check (temperature_score between 0 and 100),
  current_salary      bigint,      -- 円
  desired_salary      bigint,      -- 円
  desired_start       date,
  owner_id            uuid references staff (id),
  next_action_at      timestamptz,
  deleted_at          timestamptz, -- 論理削除（PIIは NULL にして匿名化）
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index candidates_email_unique on candidates (lower(email)) where email is not null and deleted_at is null;
create index candidates_status_idx on candidates (status) where deleted_at is null;
create trigger candidates_updated_at before update on candidates for each row execute function set_updated_at();

alter table leads
  add constraint leads_converted_candidate_fk foreign key (converted_candidate_id) references candidates (id);

create table candidate_profiles (
  candidate_id      uuid primary key references candidates (id) on delete cascade,
  summary           text,                       -- PIIを含まない要約
  skills            jsonb not null default '[]',-- [{name, years, level}]
  years_experience  numeric(4,1),
  github_username   text,
  github_analysis   jsonb,
  resume_path       text,                       -- Storage のパス
  preferences       jsonb not null default '{}',-- 希望条件（リモート・勤務地・業界など）
  embedding         vector(1024),
  updated_at        timestamptz not null default now()
);
create trigger candidate_profiles_updated_at before update on candidate_profiles for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- 同意
-- ---------------------------------------------------------------------
create table consents (
  id              uuid primary key default gen_random_uuid(),
  candidate_id    uuid references candidates (id),
  lead_id         uuid references leads (id),
  purpose         consent_purpose not null,
  policy_version  text not null,               -- 例: 'privacy-2026-11-01'
  granted_at      timestamptz not null default now(),
  revoked_at      timestamptz,
  ip_address      inet,
  user_agent      text,
  constraint consents_subject_required check (candidate_id is not null or lead_id is not null)
);
create index consents_candidate_idx on consents (candidate_id);
create index consents_lead_idx on consents (lead_id);

-- ---------------------------------------------------------------------
-- 企業
-- ---------------------------------------------------------------------
create table companies (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  website_url      text,
  careers_url      text,
  industry         text,
  employee_count   int,
  funding_stage    text,
  score            int not null default 0 check (score between 0 and 100),
  score_reason     jsonb,
  contract_status  contract_status not null default 'prospect',
  fee_rate         numeric(5,4) not null default 0.35 check (fee_rate > 0 and fee_rate <= 1),
  refund_policy    jsonb not null default '[{"within_days":30,"rate":0.8},{"within_days":90,"rate":0.5}]',
  contracted_at    date,
  owner_id         uuid references staff (id),
  next_action_at   timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index companies_website_unique on companies (lower(website_url)) where website_url is not null;
create trigger companies_updated_at before update on companies for each row execute function set_updated_at();

create table company_signals (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies (id) on delete cascade,
  signal_type  text not null,           -- 'funding' | 'job_increase' | 'ai_launch' | 'cto_hire' ...
  title        text not null,
  source_url   text,
  payload      jsonb not null default '{}',
  detected_at  timestamptz not null default now()
);
create unique index company_signals_dedupe on company_signals (company_id, signal_type, source_url);

create table contacts (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies (id) on delete cascade,
  name             text,
  title            text,
  email            text,
  source           text,              -- 取得元（名刺交換、問い合わせ、顧問紹介など）
  unsubscribed_at  timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index contacts_email_unique on contacts (lower(email)) where email is not null;
create trigger contacts_updated_at before update on contacts for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- 求人
-- ---------------------------------------------------------------------
create table jobs (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies (id) on delete cascade,
  title            text not null,
  segment          segment,
  status           job_status not null default 'draft',
  description_raw  text,                       -- 受領した求人票の原文
  structured       jsonb not null default '{}',-- LLMで構造化した結果（must_skills, nice_skills, tech_stack...）
  salary_min       bigint,
  salary_max       bigint,
  remote           remote_policy not null default 'unknown',
  location         text,
  source_url       text,
  embedding        vector(1024),
  opened_at        date,
  closed_at        date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint jobs_salary_range check (salary_min is null or salary_max is null or salary_min <= salary_max)
);
create index jobs_status_idx on jobs (status);
create trigger jobs_updated_at before update on jobs for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- 外部送信
-- ---------------------------------------------------------------------
create table message_templates (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  channel      channel not null,
  kind         message_kind not null,
  subject      text,
  body         text not null,                 -- {{placeholder}} 形式
  approved_by  uuid references staff (id),
  approved_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger message_templates_updated_at before update on message_templates for each row execute function set_updated_at();

create table outreach_sequences (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  target      text not null check (target in ('contact', 'lead', 'candidate')),
  steps       jsonb not null,   -- [{day_offset, channel, template_id | generate: true}]
  active      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table outbound_messages (
  id                    uuid primary key default gen_random_uuid(),
  channel               channel not null,
  kind                  message_kind not null,
  -- 宛先（いずれか1つ）
  contact_id            uuid references contacts (id),
  lead_id               uuid references leads (id),
  candidate_id          uuid references candidates (id),
  -- 由来
  template_id           uuid references message_templates (id),
  sequence_id           uuid references outreach_sequences (id),
  sequence_step         int,
  related_job_id        uuid references jobs (id),
  -- 本文
  subject               text,
  body                  text not null,
  ai_generated          boolean not null default false,
  ai_rationale          text,          -- なぜこの文面にしたか（承認者が読む）
  -- 状態
  status                message_status not null default 'draft',
  approved_by           uuid references staff (id),
  approved_at           timestamptz,
  scheduled_at          timestamptz,
  sent_at               timestamptz,
  provider_message_id   text,
  error                 text,
  -- 返信
  replied_at            timestamptz,
  reply_body            text,
  reply_classification  reply_class,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint outbound_one_recipient check (
    num_nonnulls(contact_id, lead_id, candidate_id) = 1
  ),
  -- 承認なしで送信状態にできない（transactional を除く）
  constraint outbound_requires_approval check (
    kind = 'transactional'
    or status not in ('approved', 'sending', 'sent')
    or approved_at is not null
  ),
  -- outreach は AI生成でもテンプレートでも、1通ずつの承認が必須
  constraint outbound_outreach_individual_approval check (
    kind <> 'outreach' or status not in ('approved', 'sending', 'sent') or approved_by is not null
  )
);
create index outbound_status_idx on outbound_messages (status, scheduled_at);
create trigger outbound_messages_updated_at before update on outbound_messages for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- やり取りの履歴（面談・商談・受信メールなど）
-- ---------------------------------------------------------------------
create table interactions (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid references candidates (id),
  company_id    uuid references companies (id),
  contact_id    uuid references contacts (id),
  channel       channel not null,
  direction     text not null check (direction in ('inbound', 'outbound', 'internal')),
  title         text,
  body          text,          -- 面談議事録など
  ai_summary    text,
  occurred_at   timestamptz not null default now(),
  created_by    uuid references staff (id),
  created_at    timestamptz not null default now()
);
create index interactions_candidate_idx on interactions (candidate_id, occurred_at desc);
create index interactions_company_idx on interactions (company_id, occurred_at desc);

-- ---------------------------------------------------------------------
-- 選考
-- ---------------------------------------------------------------------
create table applications (
  id                uuid primary key default gen_random_uuid(),
  candidate_id      uuid not null references candidates (id),
  job_id            uuid not null references jobs (id),
  stage             application_stage not null default 'proposed',
  match_score       numeric(5,4),
  match_reason      text,
  recommendation    text,           -- 推薦文（人が確定したもの）
  recommended_at    timestamptz,
  stage_changed_at  timestamptz not null default now(),
  next_action_at    timestamptz,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (candidate_id, job_id)
);
create index applications_stage_idx on applications (stage);
create trigger applications_updated_at before update on applications for each row execute function set_updated_at();

create table application_stage_events (
  id              uuid primary key default gen_random_uuid(),
  application_id  uuid not null references applications (id) on delete cascade,
  from_stage      application_stage,
  to_stage        application_stage not null,
  changed_by      uuid references staff (id),
  changed_at      timestamptz not null default now()
);

create or replace function log_application_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into application_stage_events (application_id, from_stage, to_stage, changed_by)
    values (new.id, null, new.stage, auth.uid());
  elsif new.stage is distinct from old.stage then
    new.stage_changed_at = now();
    insert into application_stage_events (application_id, from_stage, to_stage, changed_by)
    values (new.id, old.stage, new.stage, auth.uid());
  end if;
  return new;
end;
$$;
create trigger applications_stage_insert after insert on applications
  for each row execute function log_application_stage();
create trigger applications_stage_update before update of stage on applications
  for each row execute function log_application_stage();

-- ---------------------------------------------------------------------
-- 成約・請求
-- ---------------------------------------------------------------------
create table placements (
  id                         uuid primary key default gen_random_uuid(),
  application_id             uuid not null unique references applications (id),
  theoretical_annual_salary  bigint not null check (theoretical_annual_salary > 0),
  fee_rate                   numeric(5,4) not null,
  fee_amount                 bigint not null,          -- 税抜。src/domain/fee.ts で算出
  offer_accepted_at          date,
  join_date                  date not null,
  refund_deadline            date not null,            -- 返金規定の最終日
  invoice_issued_at          date,
  invoice_external_id        text,                     -- freee の請求書ID
  invoice_due_date           date,
  paid_at                    date,
  resigned_at                date,                     -- 早期退職日
  refund_amount              bigint,
  refunded_at                date,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);
create trigger placements_updated_at before update on placements for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- コンテンツ
-- ---------------------------------------------------------------------
create table content_articles (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique,
  title          text not null,
  target_keyword text,
  segment        segment,
  status         article_status not null default 'idea',
  outline        jsonb,
  body_md        text,
  ai_generated   boolean not null default false,
  reviewed_by    uuid references staff (id),  -- 技術顧問の監修
  approved_by    uuid references staff (id),
  approved_at    timestamptz,
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint articles_publish_requires_approval check (
    status not in ('approved', 'published') or approved_at is not null
  )
);
create trigger content_articles_updated_at before update on content_articles for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- 監査ログ（PIIの閲覧・エクスポート・削除）
-- ---------------------------------------------------------------------
create table audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  action      text not null,          -- 'view_pii' | 'export' | 'anonymize' ...
  target      text not null,          -- 'candidates:<uuid>'
  detail      jsonb,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- RLS
-- =====================================================================
alter table staff                    enable row level security;
alter table leads                    enable row level security;
alter table candidates               enable row level security;
alter table candidate_profiles       enable row level security;
alter table consents                 enable row level security;
alter table companies                enable row level security;
alter table company_signals          enable row level security;
alter table contacts                 enable row level security;
alter table jobs                     enable row level security;
alter table message_templates        enable row level security;
alter table outreach_sequences       enable row level security;
alter table outbound_messages        enable row level security;
alter table interactions             enable row level security;
alter table applications             enable row level security;
alter table application_stage_events enable row level security;
alter table placements               enable row level security;
alter table content_articles         enable row level security;
alter table audit_logs               enable row level security;

-- staff: 自分の行は読める、admin は全件
create policy staff_select on staff for select using (id = auth.uid() or is_admin());
create policy staff_admin_all on staff for all using (is_admin()) with check (is_admin());

-- admin はすべての業務テーブルを操作できる
do $$
declare t text;
begin
  foreach t in array array[
    'leads','candidates','candidate_profiles','consents','companies','company_signals',
    'contacts','jobs','message_templates','outreach_sequences','outbound_messages',
    'interactions','applications','application_stage_events','placements','content_articles'
  ] loop
    execute format('create policy %I on %I for all using (is_admin()) with check (is_admin())', t || '_admin_all', t);
  end loop;
end $$;

-- advisor は候補者のPIIを見られない。候補者は下の candidates_for_advisor ビュー経由でのみ参照する
create policy candidate_profiles_advisor_select on candidate_profiles for select using (is_staff());
create policy companies_advisor_select          on companies          for select using (is_staff());
create policy jobs_advisor_select               on jobs               for select using (is_staff());
create policy applications_advisor_select       on applications       for select using (is_staff());
create policy content_articles_advisor_select   on content_articles   for select using (is_staff());
-- advisor は記事の監修（reviewed_by の設定）ができる
create policy content_articles_advisor_review   on content_articles   for update using (is_staff()) with check (is_staff());

-- 監査ログ: 誰でも（staffなら）追記できる、閲覧は admin のみ
create policy audit_logs_insert on audit_logs for insert with check (is_staff());
create policy audit_logs_select on audit_logs for select using (is_admin());

-- =====================================================================
-- ビュー
-- =====================================================================

-- advisor 向け: PIIを除いた候補者
create view candidates_for_advisor with (security_barrier) as
select c.id, c.segment, c.status, c.temperature_score, c.desired_salary,
       p.summary, p.skills, p.years_experience, p.github_analysis
from candidates c
left join candidate_profiles p on p.candidate_id = c.id
where c.deleted_at is null and is_staff();

-- 承認待ちキュー
create view v_approval_queue with (security_invoker = true) as
select 'message'::text as item_type, m.id, m.channel::text as channel, m.kind::text as kind,
       coalesce(m.subject, left(m.body, 60)) as title, m.ai_rationale as note, m.created_at
from outbound_messages m
where m.status = 'pending_approval'
union all
select 'article', a.id, 'web', 'content', a.title,
       case when a.reviewed_by is null then '技術顧問の監修待ち' else '監修済み' end, a.created_at
from content_articles a
where a.status = 'review';

-- 送信可能なメッセージ（ジョブが参照する）。同意・配信停止をここで一元的にチェックする
create view v_sendable_messages with (security_invoker = true) as
select m.*
from outbound_messages m
left join contacts ct  on ct.id = m.contact_id
left join leads l      on l.id = m.lead_id
left join candidates c on c.id = m.candidate_id
where m.status = 'approved'
  and (m.scheduled_at is null or m.scheduled_at <= now())
  and (m.contact_id is null or ct.unsubscribed_at is null)
  and (m.lead_id is null or l.unsubscribed_at is null)
  and (m.candidate_id is null or c.deleted_at is null)
  and (
    m.kind = 'transactional'
    or m.contact_id is not null  -- 法人宛は同意ではなく配信停止で管理
    or exists (
      select 1 from consents cs
      where cs.revoked_at is null
        and cs.purpose = case m.channel when 'line' then 'marketing_line'::consent_purpose
                                        else 'marketing_email'::consent_purpose end
        and (cs.lead_id = m.lead_id or cs.candidate_id = m.candidate_id)
    )
    or (m.kind = 'outreach' and m.candidate_id is not null and exists (
      select 1 from consents cs
      where cs.revoked_at is null and cs.purpose = 'job_introduction' and cs.candidate_id = m.candidate_id
    ))
  );

-- 求人管理簿
create view v_job_ledger with (security_invoker = true) as
select j.id as job_id, co.name as company_name, j.title, j.segment,
       j.salary_min, j.salary_max, j.location, j.opened_at, j.closed_at, j.status,
       (select count(*) from applications a where a.job_id = j.id and a.stage = 'joined') as placements
from jobs j
join companies co on co.id = j.company_id;

-- 求職管理簿
create view v_candidate_ledger with (security_invoker = true) as
select c.id as candidate_id, c.full_name, c.segment, c.created_at::date as registered_on,
       c.desired_salary, c.status,
       (select string_agg(co.name || ' / ' || j.title, ', ')
          from applications a join jobs j on j.id = a.job_id join companies co on co.id = j.company_id
         where a.candidate_id = c.id and a.stage = 'joined') as placed_at
from candidates c
where c.deleted_at is null;

-- 事業報告・情報公開用（年度 = 4月〜翌3月）
create view v_annual_report with (security_invoker = true) as
select
  case when extract(month from p.join_date) >= 4 then extract(year from p.join_date)::int
       else extract(year from p.join_date)::int - 1 end                       as fiscal_year,
  count(*)                                                                    as placements,
  count(*) filter (where p.resigned_at is not null
                     and p.resigned_at < p.join_date + interval '6 months')    as resigned_within_6_months,
  sum(p.fee_amount)                                                           as fee_total,
  round(avg(p.fee_rate), 4)                                                   as avg_fee_rate,
  round(avg(p.theoretical_annual_salary))                                     as avg_annual_salary
from placements p
group by 1;

-- ファネルKPI（候補者の流入元別）
create view v_funnel_kpi with (security_invoker = true) as
select
  c.source,
  date_trunc('month', c.created_at)::date as cohort_month,
  count(distinct c.id)                                                         as registered,
  count(distinct c.id) filter (where c.status not in ('new', 'nurturing'))     as interviewed,
  count(distinct a.candidate_id) filter (where a.recommended_at is not null)   as recommended,
  count(distinct a.candidate_id) filter (where a.stage in ('offer','accepted','joined')) as offered,
  count(distinct a.candidate_id) filter (where a.stage = 'joined')             as joined
from candidates c
left join applications a on a.candidate_id = c.id
where c.deleted_at is null
group by 1, 2;
