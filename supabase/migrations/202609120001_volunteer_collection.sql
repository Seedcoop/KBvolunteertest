create extension if not exists pgcrypto with schema extensions;

create table if not exists public.volunteer_events (
  event_slug text primary key,
  activation_code_hash text not null,
  is_active boolean not null default true,
  token_ttl_minutes smallint not null default 720,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint volunteer_events_slug_format
    check (event_slug ~ '^[a-z0-9][a-z0-9-]{2,63}$'),
  constraint volunteer_events_activation_hash_format
    check (activation_code_hash ~ '^[0-9a-f]{64}$'),
  constraint volunteer_events_token_ttl_range
    check (token_ttl_minutes between 60 and 720)
);

comment on table public.volunteer_events is
  'Server-only settings for volunteer profile collection events.';

create or replace function public.is_valid_volunteer_answers(p_answers jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog, public
as $$
  select case
    when jsonb_typeof(p_answers) <> 'array' then false
    when jsonb_array_length(p_answers) <> 30 then false
    else not exists (
      select 1
      from jsonb_array_elements(p_answers) as answer(value)
      where not (
        (jsonb_typeof(answer.value) = 'number'
          and answer.value #>> '{}' in ('1', '2', '3', '4', '5'))
        or answer.value = to_jsonb('unsure'::text)
      )
    )
  end;
$$;

create table if not exists public.volunteer_submissions (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null,
  event_slug text not null references public.volunteer_events(event_slug),
  participant_name text not null,
  affiliation text not null,
  score_p numeric(2, 1),
  score_v numeric(2, 1),
  score_c numeric(2, 1),
  score_s numeric(2, 1),
  score_u numeric(2, 1),
  score_e numeric(2, 1),
  rank_p smallint,
  rank_v smallint,
  rank_c smallint,
  rank_s smallint,
  rank_u smallint,
  rank_e smallint,
  top_motives text[] not null default '{}'::text[],
  answers jsonb not null,
  scores jsonb not null,
  ranks jsonb not null,
  unknown_count smallint not null,
  instrument_version text not null,
  notice_version text not null,
  revision integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint volunteer_submissions_name_length
    check (char_length(btrim(participant_name)) between 1 and 40),
  constraint volunteer_submissions_affiliation_length
    check (char_length(btrim(affiliation)) between 1 and 80),
  constraint volunteer_submissions_submission_id_key unique (submission_id),
  constraint volunteer_submissions_score_p_range check (score_p between 1 and 5),
  constraint volunteer_submissions_score_v_range check (score_v between 1 and 5),
  constraint volunteer_submissions_score_c_range check (score_c between 1 and 5),
  constraint volunteer_submissions_score_s_range check (score_s between 1 and 5),
  constraint volunteer_submissions_score_u_range check (score_u between 1 and 5),
  constraint volunteer_submissions_score_e_range check (score_e between 1 and 5),
  constraint volunteer_submissions_rank_p_range check (rank_p between 1 and 6),
  constraint volunteer_submissions_rank_v_range check (rank_v between 1 and 6),
  constraint volunteer_submissions_rank_c_range check (rank_c between 1 and 6),
  constraint volunteer_submissions_rank_s_range check (rank_s between 1 and 6),
  constraint volunteer_submissions_rank_u_range check (rank_u between 1 and 6),
  constraint volunteer_submissions_rank_e_range check (rank_e between 1 and 6),
  constraint volunteer_submissions_answers_valid
    check (public.is_valid_volunteer_answers(answers)),
  constraint volunteer_submissions_scores_object
    check (jsonb_typeof(scores) = 'object'),
  constraint volunteer_submissions_ranks_object
    check (jsonb_typeof(ranks) = 'object'),
  constraint volunteer_submissions_unknown_count_range
    check (unknown_count between 0 and 30),
  constraint volunteer_submissions_instrument_version_length
    check (char_length(instrument_version) between 1 and 64),
  constraint volunteer_submissions_notice_version_length
    check (char_length(notice_version) between 1 and 64),
  constraint volunteer_submissions_revision_positive
    check (revision >= 1)
);

comment on table public.volunteer_submissions is
  'Private participant responses and server-calculated volunteer motive results.';
comment on column public.volunteer_submissions.submission_id is
  'Browser-generated idempotency key reused when a participant edits an answer.';
comment on column public.volunteer_submissions.score_p is '보호 동기 평균 점수';
comment on column public.volunteer_submissions.score_v is '가치 동기 평균 점수';
comment on column public.volunteer_submissions.score_c is '진로 동기 평균 점수';
comment on column public.volunteer_submissions.score_s is '사회 동기 평균 점수';
comment on column public.volunteer_submissions.score_u is '이해 동기 평균 점수';
comment on column public.volunteer_submissions.score_e is '성장 동기 평균 점수';
comment on column public.volunteer_submissions.top_motives is
  '공동 1위를 포함한 최고 동기 이름. 점수 미완성 시 빈 배열.';

create index if not exists volunteer_submissions_event_created_idx
  on public.volunteer_submissions (event_slug, created_at desc);

create or replace function public.upsert_volunteer_submission(
  p_submission_id uuid,
  p_event_slug text,
  p_participant_name text,
  p_affiliation text,
  p_answers jsonb,
  p_scores jsonb,
  p_ranks jsonb,
  p_unknown_count smallint,
  p_instrument_version text,
  p_notice_version text
)
returns table (
  submission_id uuid,
  revision integer,
  saved_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  return query
  insert into public.volunteer_submissions (
    submission_id,
    event_slug,
    participant_name,
    affiliation,
    score_p,
    score_v,
    score_c,
    score_s,
    score_u,
    score_e,
    rank_p,
    rank_v,
    rank_c,
    rank_s,
    rank_u,
    rank_e,
    top_motives,
    answers,
    scores,
    ranks,
    unknown_count,
    instrument_version,
    notice_version
  ) values (
    p_submission_id,
    p_event_slug,
    btrim(p_participant_name),
    btrim(p_affiliation),
    (p_scores ->> 'P')::numeric(2, 1),
    (p_scores ->> 'V')::numeric(2, 1),
    (p_scores ->> 'C')::numeric(2, 1),
    (p_scores ->> 'S')::numeric(2, 1),
    (p_scores ->> 'U')::numeric(2, 1),
    (p_scores ->> 'E')::numeric(2, 1),
    (p_ranks ->> 'P')::smallint,
    (p_ranks ->> 'V')::smallint,
    (p_ranks ->> 'C')::smallint,
    (p_ranks ->> 'S')::smallint,
    (p_ranks ->> 'U')::smallint,
    (p_ranks ->> 'E')::smallint,
    array_remove(array[
      case when (p_ranks ->> 'P')::smallint = 1 then '보호' end,
      case when (p_ranks ->> 'V')::smallint = 1 then '가치' end,
      case when (p_ranks ->> 'C')::smallint = 1 then '진로' end,
      case when (p_ranks ->> 'S')::smallint = 1 then '사회' end,
      case when (p_ranks ->> 'U')::smallint = 1 then '이해' end,
      case when (p_ranks ->> 'E')::smallint = 1 then '성장' end
    ], null),
    p_answers,
    p_scores,
    p_ranks,
    p_unknown_count,
    p_instrument_version,
    p_notice_version
  )
  on conflict on constraint volunteer_submissions_submission_id_key do update
    set participant_name = excluded.participant_name,
        affiliation = excluded.affiliation,
        score_p = excluded.score_p,
        score_v = excluded.score_v,
        score_c = excluded.score_c,
        score_s = excluded.score_s,
        score_u = excluded.score_u,
        score_e = excluded.score_e,
        rank_p = excluded.rank_p,
        rank_v = excluded.rank_v,
        rank_c = excluded.rank_c,
        rank_s = excluded.rank_s,
        rank_u = excluded.rank_u,
        rank_e = excluded.rank_e,
        top_motives = excluded.top_motives,
        answers = excluded.answers,
        scores = excluded.scores,
        ranks = excluded.ranks,
        unknown_count = excluded.unknown_count,
        instrument_version = excluded.instrument_version,
        notice_version = excluded.notice_version,
        revision = public.volunteer_submissions.revision + 1,
        updated_at = now()
    where public.volunteer_submissions.event_slug = excluded.event_slug
  returning
    public.volunteer_submissions.submission_id,
    public.volunteer_submissions.revision,
    public.volunteer_submissions.updated_at;

  if not found then
    raise exception using
      errcode = '23514',
      message = 'submission_id is already assigned to another event';
  end if;
end;
$$;

alter table public.volunteer_events enable row level security;
alter table public.volunteer_events force row level security;
alter table public.volunteer_submissions enable row level security;
alter table public.volunteer_submissions force row level security;

create or replace view public.volunteer_submissions_export
with (security_invoker = true, security_barrier = true)
as
select
  s.submission_id,
  s.event_slug,
  case
    when s.participant_name ~ '^[[:space:]]*[-+=@]'
      then chr(39) || s.participant_name
    else s.participant_name
  end as participant_name,
  case
    when s.affiliation ~ '^[[:space:]]*[-+=@]'
      then chr(39) || s.affiliation
    else s.affiliation
  end as affiliation,
  s.score_p,
  s.score_v,
  s.score_c,
  s.score_s,
  s.score_u,
  s.score_e,
  s.rank_p,
  s.rank_v,
  s.rank_c,
  s.rank_s,
  s.rank_u,
  s.rank_e,
  array_to_string(s.top_motives, ', ') as top_motives,
  s.unknown_count,
  s.answers ->> 0 as q01,
  s.answers ->> 1 as q02,
  s.answers ->> 2 as q03,
  s.answers ->> 3 as q04,
  s.answers ->> 4 as q05,
  s.answers ->> 5 as q06,
  s.answers ->> 6 as q07,
  s.answers ->> 7 as q08,
  s.answers ->> 8 as q09,
  s.answers ->> 9 as q10,
  s.answers ->> 10 as q11,
  s.answers ->> 11 as q12,
  s.answers ->> 12 as q13,
  s.answers ->> 13 as q14,
  s.answers ->> 14 as q15,
  s.answers ->> 15 as q16,
  s.answers ->> 16 as q17,
  s.answers ->> 17 as q18,
  s.answers ->> 18 as q19,
  s.answers ->> 19 as q20,
  s.answers ->> 20 as q21,
  s.answers ->> 21 as q22,
  s.answers ->> 22 as q23,
  s.answers ->> 23 as q24,
  s.answers ->> 24 as q25,
  s.answers ->> 25 as q26,
  s.answers ->> 26 as q27,
  s.answers ->> 27 as q28,
  s.answers ->> 28 as q29,
  s.answers ->> 29 as q30,
  s.instrument_version,
  s.notice_version,
  s.revision,
  s.created_at at time zone 'Asia/Seoul' as created_at_kst,
  s.updated_at at time zone 'Asia/Seoul' as updated_at_kst
from public.volunteer_submissions as s;

comment on view public.volunteer_submissions_export is
  'Dashboard-only Excel/CSV export of saved volunteer profile submissions.';

revoke all on table public.volunteer_events from anon, authenticated;
revoke all on table public.volunteer_submissions from anon, authenticated;
revoke all on table public.volunteer_submissions_export
  from public, anon, authenticated;
grant all on table public.volunteer_events to service_role;
grant all on table public.volunteer_submissions to service_role;
grant select on table public.volunteer_submissions_export to service_role;

revoke all on function public.is_valid_volunteer_answers(jsonb)
  from public, anon, authenticated;
grant execute on function public.is_valid_volunteer_answers(jsonb)
  to service_role;

revoke all on function public.upsert_volunteer_submission(
  uuid, text, text, text, jsonb, jsonb, jsonb, smallint, text, text
) from public, anon, authenticated;
grant execute on function public.upsert_volunteer_submission(
  uuid, text, text, text, jsonb, jsonb, jsonb, smallint, text, text
) to service_role;
