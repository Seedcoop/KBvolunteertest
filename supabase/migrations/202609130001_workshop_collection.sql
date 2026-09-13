-- Append-only collection for the KB AI / vibe-coding workshop.
-- This migration is independent of the existing volunteer survey tables.
-- Browser clients may invoke one bounded RPC; they cannot read or mutate rows.
begin;

create table if not exists public.workshop_prompt_submissions (
  submission_id uuid primary key,
  client_id uuid not null,
  team_name text not null,
  team_key text generated always as (
    pg_catalog.lower(pg_catalog.regexp_replace(team_name, '[[:space:]]+', ' ', 'g'))
  ) stored,
  project_name text not null,
  project jsonb not null,
  design jsonb not null,
  prompt text not null,
  output_filename text generated always as (team_name || '.html') stored,
  client_created_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint workshop_prompt_team_length
    check (pg_catalog.char_length(team_name) between 1 and 80),
  constraint workshop_prompt_team_trimmed
    check (team_name = pg_catalog.btrim(team_name)),
  constraint workshop_prompt_team_filename_characters
    check (team_name !~ '[<>:"/\\|?*[:cntrl:]]' and team_name !~ '[. ]$'),
  constraint workshop_prompt_team_filename_reserved
    check (pg_catalog.upper(pg_catalog.split_part(team_name, '.', 1))
      !~ '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$'),
  constraint workshop_prompt_project_name_length
    check (pg_catalog.char_length(project_name) between 1 and 200),
  constraint workshop_prompt_project_object
    check (pg_catalog.jsonb_typeof(project) = 'object'
      and pg_catalog.octet_length(project::text) <= 30000),
  constraint workshop_prompt_design_object
    check (pg_catalog.jsonb_typeof(design) = 'object'
      and pg_catalog.octet_length(design::text) <= 10000),
  constraint workshop_prompt_body_length
    check (pg_catalog.char_length(pg_catalog.btrim(prompt)) between 1 and 60000),
  constraint workshop_prompt_client_time_finite
    check (pg_catalog.isfinite(client_created_at))
);

comment on table public.workshop_prompt_submissions is
  'Private append-only snapshots collected when a team copies a production prompt. No browser SELECT, INSERT, UPDATE, or DELETE access.';
comment on column public.workshop_prompt_submissions.submission_id is
  'Browser UUID for one copy event. Reuse for every retry; generate a fresh UUID for a new copy event.';
comment on column public.workshop_prompt_submissions.client_id is
  'Random browser-installation UUID for retry ownership and accidental-burst limiting; not an authenticated identity.';
comment on column public.workshop_prompt_submissions.team_key is
  'Grouping key: trimmed team name with whitespace collapsed and letters lowercased. Team name is not an authentication credential.';
comment on column public.workshop_prompt_submissions.output_filename is
  'Exact requested deliverable name: team_name plus .html.';
comment on column public.workshop_prompt_submissions.client_created_at is
  'Untrusted client copy-event timestamp, retained to order snapshots queued while offline.';
comment on column public.workshop_prompt_submissions.created_at is
  'Server acceptance timestamp, used for collection order and rate limiting.';

create index if not exists workshop_prompt_team_created_idx
  on public.workshop_prompt_submissions (team_key, created_at desc);
create index if not exists workshop_prompt_client_created_idx
  on public.workshop_prompt_submissions (client_id, created_at desc);

alter table public.workshop_prompt_submissions enable row level security;
revoke all on table public.workshop_prompt_submissions from public, anon, authenticated;
-- Deliberately no RLS policies: the only browser write path is the definer RPC.

create or replace function public.collect_workshop_prompt(
  p_submission_id uuid,
  p_client_id uuid,
  p_team_name text,
  p_project_name text,
  p_project jsonb,
  p_design jsonb,
  p_prompt text,
  p_client_created_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_team_name text;
  v_project_name text;
  v_field text;
  v_section jsonb;
  v_now timestamptz;
  v_created_at timestamptz;
  v_existing_client_id uuid;
  v_recent_count integer;
begin
  if p_submission_id is null or p_client_id is null then
    raise sqlstate 'PT400' using message = 'submission_id_and_client_id_required';
  end if;

  -- Serialize each browser's writes so concurrent requests cannot overshoot
  -- the burst limit. Hash collisions only serialize unrelated clients.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('workshop_prompt_client:' || p_client_id::text, 0)
  );

  select s.client_id, s.created_at
    into v_existing_client_id, v_created_at
    from public.workshop_prompt_submissions as s
    where s.submission_id = p_submission_id;
  if found then
    if v_existing_client_id <> p_client_id then
      raise sqlstate 'PT409' using message = 'submission_id_conflict';
    end if;
    -- A retry acknowledges the original event without changing any content.
    -- Do this before validation/rate checks so accepted queued events stay safe.
    return pg_catalog.jsonb_build_object(
      'accepted', true, 'submission_id', p_submission_id, 'created_at', v_created_at
    );
  end if;

  v_team_name := pg_catalog.btrim(p_team_name);
  v_project_name := pg_catalog.btrim(p_project_name);

  if v_team_name is null
      or pg_catalog.char_length(v_team_name) not between 1 and 80
      or v_team_name ~ '[<>:"/\\|?*[:cntrl:]]'
      or v_team_name ~ '[. ]$'
      or pg_catalog.upper(pg_catalog.split_part(v_team_name, '.', 1))
        ~ '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$' then
    raise sqlstate 'PT400' using message = 'team_name_must_be_a_valid_windows_filename';
  end if;
  if v_project_name is null
      or pg_catalog.char_length(v_project_name) not between 1 and 200 then
    raise sqlstate 'PT400' using message = 'project_name_required_max_200_characters';
  end if;
  if p_prompt is null
      or pg_catalog.char_length(pg_catalog.btrim(p_prompt)) = 0
      or pg_catalog.char_length(p_prompt) > 60000 then
    raise sqlstate 'PT400' using message = 'prompt_required_max_60000_characters';
  end if;
  if p_client_created_at is null or not pg_catalog.isfinite(p_client_created_at) then
    raise sqlstate 'PT400' using message = 'finite_client_created_at_required';
  end if;
  if p_project is null or pg_catalog.jsonb_typeof(p_project) <> 'object'
      or pg_catalog.octet_length(p_project::text) > 30000 then
    raise sqlstate 'PT400' using message = 'project_must_be_object_max_30000_bytes';
  end if;
  foreach v_field in array array[
    'team', 'name', 'tagline', 'target', 'problem', 'activity', 'change', 'plan'
  ] loop
    if pg_catalog.jsonb_typeof(p_project -> v_field) is distinct from 'string'
        or pg_catalog.char_length(pg_catalog.btrim(p_project ->> v_field)) = 0
        or pg_catalog.char_length(p_project ->> v_field) > 5000 then
      raise sqlstate 'PT400' using
        message = 'project_field_required_max_5000_characters', detail = v_field;
    end if;
  end loop;
  if pg_catalog.btrim(p_project ->> 'team') <> v_team_name
      or pg_catalog.btrim(p_project ->> 'name') <> v_project_name then
    raise sqlstate 'PT400' using message = 'project_names_must_match_parameters';
  end if;

  if p_design is null or pg_catalog.jsonb_typeof(p_design) <> 'object'
      or pg_catalog.octet_length(p_design::text) > 10000 then
    raise sqlstate 'PT400' using message = 'design_must_be_object_max_10000_bytes';
  end if;
  if pg_catalog.jsonb_typeof(p_design -> 'sections') is distinct from 'array'
      or pg_catalog.jsonb_typeof(p_design -> 'tone') is distinct from 'string'
      or (p_design -> 'confirmed') is distinct from 'true'::jsonb then
    raise sqlstate 'PT400' using message = 'design_requires_sections_tone_and_confirmed';
  end if;
  if pg_catalog.jsonb_array_length(p_design -> 'sections') not between 1 and 12
      or pg_catalog.char_length(pg_catalog.btrim(p_design ->> 'tone')) = 0
      or pg_catalog.char_length(p_design ->> 'tone') > 5000 then
    raise sqlstate 'PT400' using message = 'design_sections_or_tone_out_of_range';
  end if;
  for v_section in select value
      from pg_catalog.jsonb_array_elements(p_design -> 'sections') loop
    if pg_catalog.jsonb_typeof(v_section) <> 'string'
        or pg_catalog.char_length(pg_catalog.btrim(v_section #>> '{}')) = 0
        or pg_catalog.char_length(v_section #>> '{}') > 120 then
      raise sqlstate 'PT400' using message = 'design_sections_must_be_nonempty_strings_max_120_characters';
    end if;
  end loop;

  v_now := pg_catalog.clock_timestamp();
  select pg_catalog.count(*)::integer into v_recent_count
    from public.workshop_prompt_submissions as s
    where s.client_id = p_client_id
      and s.created_at >= v_now - interval '1 hour';
  if v_recent_count >= 60 then
    raise sqlstate 'PT429' using
      message = 'collection_rate_limit_exceeded',
      hint = 'Keep the event queued and retry later; the limit is 60 new copy events per browser per hour.';
  end if;

  insert into public.workshop_prompt_submissions (
    submission_id, client_id, team_name, project_name, project, design,
    prompt, client_created_at, created_at
  ) values (
    p_submission_id, p_client_id, v_team_name, v_project_name, p_project, p_design,
    p_prompt, p_client_created_at, v_now
  ) on conflict (submission_id) do nothing
  returning created_at into v_created_at;

  if not found then
    -- Covers a simultaneous UUID collision from another browser; never update.
    select s.created_at into v_created_at
      from public.workshop_prompt_submissions as s
      where s.submission_id = p_submission_id and s.client_id = p_client_id;
    if not found then
      raise sqlstate 'PT409' using message = 'submission_id_conflict';
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'accepted', true, 'submission_id', p_submission_id, 'created_at', v_created_at
  );
end;
$function$;

comment on function public.collect_workshop_prompt(uuid, uuid, text, text, jsonb, jsonb, text, timestamptz) is
  'Anonymous append-only prompt collection. Validates bounded payloads, deduplicates copy-event UUIDs, and limits each untrusted client UUID to 60 new events/hour. Returns receipt only; never returns stored project content.';

revoke all on function public.collect_workshop_prompt(uuid, uuid, text, text, jsonb, jsonb, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.collect_workshop_prompt(uuid, uuid, text, text, jsonb, jsonb, text, timestamptz)
  to anon, authenticated;

-- Tell the REST API to reload the new RPC signature after the commit.
notify pgrst, 'reload schema';
commit;
