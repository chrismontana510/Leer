-- Supabase setup for the clinical psychology quiz
-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run.

create table if not exists public.quiz_question_stats (
  question_id text primary key,
  question_text text not null,
  topic text not null,
  question_type text not null,
  attempts bigint not null default 0 check (attempts >= 0),
  correct_attempts bigint not null default 0 check (correct_attempts >= 0),
  last_attempt_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quiz_question_stats_correct_lte_attempts
    check (correct_attempts <= attempts)
);

alter table public.quiz_question_stats enable row level security;

-- No direct table access from the public browser client.
revoke all on table public.quiz_question_stats from anon, authenticated;

create or replace function public.record_quiz_attempt(
  p_question_id text,
  p_question_text text,
  p_topic text,
  p_question_type text,
  p_is_correct boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.quiz_question_stats;
begin
  if p_question_id is null or length(trim(p_question_id)) = 0 or length(p_question_id) > 180 then
    raise exception 'Invalid question id';
  end if;

  if p_question_text is null or length(trim(p_question_text)) = 0 or length(p_question_text) > 1000 then
    raise exception 'Invalid question text';
  end if;

  insert into public.quiz_question_stats (
    question_id,
    question_text,
    topic,
    question_type,
    attempts,
    correct_attempts,
    last_attempt_at,
    updated_at
  )
  values (
    trim(p_question_id),
    left(trim(p_question_text), 1000),
    left(coalesce(nullif(trim(p_topic), ''), 'Unbekannt'), 120),
    left(coalesce(nullif(trim(p_question_type), ''), 'Unbekannt'), 80),
    1,
    case when coalesce(p_is_correct, false) then 1 else 0 end,
    now(),
    now()
  )
  on conflict (question_id) do update
  set question_text = excluded.question_text,
      topic = excluded.topic,
      question_type = excluded.question_type,
      attempts = public.quiz_question_stats.attempts + 1,
      correct_attempts = public.quiz_question_stats.correct_attempts
        + case when coalesce(p_is_correct, false) then 1 else 0 end,
      last_attempt_at = now(),
      updated_at = now()
  returning * into v_row;

  return jsonb_build_object(
    'question_id', v_row.question_id,
    'attempts', v_row.attempts,
    'correct_attempts', v_row.correct_attempts,
    'success_rate', round((v_row.correct_attempts::numeric / nullif(v_row.attempts, 0)) * 100, 1)
  );
end;
$$;

create or replace function public.get_quiz_analytics(p_limit integer default 100)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  with question_rows as (
    select
      question_id,
      question_text,
      topic,
      question_type,
      attempts,
      correct_attempts,
      round((correct_attempts::numeric / nullif(attempts, 0)) * 100, 1) as success_rate,
      last_attempt_at
    from public.quiz_question_stats
    order by
      case when attempts >= 3 then 0 else 1 end,
      (correct_attempts::numeric / nullif(attempts, 0)) asc nulls last,
      attempts desc,
      last_attempt_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 500))
  ),
  topic_rows as (
    select
      topic,
      sum(attempts)::bigint as attempts,
      sum(correct_attempts)::bigint as correct_attempts,
      round((sum(correct_attempts)::numeric / nullif(sum(attempts), 0)) * 100, 1) as success_rate,
      count(*)::bigint as question_count
    from public.quiz_question_stats
    group by topic
    order by success_rate asc nulls last, attempts desc
  ),
  totals as (
    select
      coalesce(sum(attempts), 0)::bigint as attempts,
      coalesce(sum(correct_attempts), 0)::bigint as correct_attempts,
      case
        when coalesce(sum(attempts), 0) = 0 then null
        else round((sum(correct_attempts)::numeric / sum(attempts)) * 100, 1)
      end as success_rate,
      count(*)::bigint as question_count
    from public.quiz_question_stats
  )
  select jsonb_build_object(
    'totals', (select to_jsonb(totals) from totals),
    'topics', coalesce((select jsonb_agg(to_jsonb(topic_rows)) from topic_rows), '[]'::jsonb),
    'questions', coalesce((select jsonb_agg(to_jsonb(question_rows)) from question_rows), '[]'::jsonb)
  );
$$;

revoke execute on function public.record_quiz_attempt(text, text, text, text, boolean) from public;
revoke execute on function public.get_quiz_analytics(integer) from public;

grant execute on function public.record_quiz_attempt(text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.get_quiz_analytics(integer) to anon, authenticated;

comment on table public.quiz_question_stats is
  'Aggregated anonymous quiz statistics. Stores no names, email addresses or free-text learner responses.';
