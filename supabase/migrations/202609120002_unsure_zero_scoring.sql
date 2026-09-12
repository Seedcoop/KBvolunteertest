begin;

alter table public.volunteer_submissions
  drop constraint volunteer_submissions_score_p_range,
  drop constraint volunteer_submissions_score_v_range,
  drop constraint volunteer_submissions_score_c_range,
  drop constraint volunteer_submissions_score_s_range,
  drop constraint volunteer_submissions_score_u_range,
  drop constraint volunteer_submissions_score_e_range,
  add constraint volunteer_submissions_score_p_range
    check (score_p between 0 and 5),
  add constraint volunteer_submissions_score_v_range
    check (score_v between 0 and 5),
  add constraint volunteer_submissions_score_c_range
    check (score_c between 0 and 5),
  add constraint volunteer_submissions_score_s_range
    check (score_s between 0 and 5),
  add constraint volunteer_submissions_score_u_range
    check (score_u between 0 and 5),
  add constraint volunteer_submissions_score_e_range
    check (score_e between 0 and 5);

comment on column public.volunteer_submissions.unknown_count is
  'Number of raw unsure responses. Version 2 keeps them as unsure and scores them as zero.';

commit;
