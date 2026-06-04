-- ============================================================
-- Supabase 数据库初始化脚本
-- 在 Supabase Dashboard → SQL Editor 中粘贴运行
-- ============================================================

-- 1) 投票表：每行存一个问题的所有选项票数
create table if not exists public.votes (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);

-- 2) 写入初始数据（Q1 三个选项，Q2 两个选项）
insert into public.votes (id, data) values
  ('q1', '{"A":0,"B":0,"C":0}'::jsonb),
  ('q2', '{"A":0,"B":0}'::jsonb)
on conflict (id) do nothing;

-- 3) 原子递增 RPC：避免并发竞态
create or replace function public.increment_vote(qid text, opt text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if opt !~ '^[A-Z]$' then
    raise exception 'invalid option';
  end if;
  update public.votes
  set data = jsonb_set(
        data,
        array[opt],
        to_jsonb(coalesce((data->>opt)::int, 0) + 1)
      ),
      updated_at = now()
  where id = qid
  returning data into result;
  return result;
end;
$$;

-- 4) 行级安全
alter table public.votes enable row level security;

drop policy if exists "read_all" on public.votes;
create policy "read_all" on public.votes for select using (true);

-- 允许匿名用户执行递增函数
grant execute on function public.increment_vote(text, text) to anon, authenticated;
grant select on public.votes to anon, authenticated;

-- 4.5) 重置票数 RPC（带密码，防止被乱清）
-- 演讲前在 SQL Editor 跑：select public.reset_votes('reset2026');
-- 或在大屏按 Shift+R 弹密码框
create or replace function public.reset_votes(secret text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if secret is null or secret <> 'reset2026' then
    raise exception 'wrong password';
  end if;
  update public.votes set data = '{"A":0,"B":0,"C":0}'::jsonb, updated_at = now() where id = 'q1';
  update public.votes set data = '{"A":0,"B":0}'::jsonb,       updated_at = now() where id = 'q2';
  return jsonb_build_object('ok', true, 'reset_at', now());
end;
$$;

grant execute on function public.reset_votes(text) to anon, authenticated;

-- 5) 开启 Realtime（幂等：已加过就跳过）
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'votes'
  ) then
    alter publication supabase_realtime add table public.votes;
  end if;
end $$;

-- 完成。验证：
--   select * from public.votes;
--   select public.increment_vote('q1','A');
