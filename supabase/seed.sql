-- 開発用ダミーデータ（実在の人物・企業を使わない）
-- staff はローカルで Auth ユーザーを作成したあとに、その id で登録する:
--   insert into staff (id, name, role) values ('<auth.users.id>', '開発者', 'admin');

insert into companies (name, website_url, industry, employee_count, funding_stage, contract_status, score) values
  ('サンプルSaaS株式会社',   'https://example.com/saas', 'SaaS',     80,  'Series B', 'contracted', 82),
  ('ダミーAIラボ株式会社',   'https://example.com/ai',   'AI',       35,  'Series A', 'negotiating', 74),
  ('テスト商事株式会社',     'https://example.com/corp', 'EC',       400, 'Listed',   'prospect',   40);

insert into jobs (company_id, title, segment, status, salary_min, salary_max, remote, structured)
select id, 'バックエンドエンジニア（Go）', 'web', 'open', 6000000, 8500000, 'hybrid',
       '{"must_skills":["Go","AWS"],"nice_skills":["Kubernetes"]}'::jsonb
from companies where name = 'サンプルSaaS株式会社';

insert into jobs (company_id, title, segment, status, salary_min, salary_max, remote, structured)
select id, 'LLMアプリケーションエンジニア', 'web_to_ai', 'open', 8000000, 11000000, 'full_remote',
       '{"must_skills":["Python","LLM API"],"nice_skills":["RAG","評価設計"]}'::jsonb
from companies where name = 'ダミーAIラボ株式会社';

insert into candidates (segment, status, source, temperature_score, current_salary, desired_salary) values
  ('web',       'active',    'diagnosis', 70, 6500000, 7500000),
  ('web_to_ai', 'nurturing', 'line',      40, 7000000, 9000000),
  ('ai_ml',     'new',       'article',   20, 9000000, 11000000);
