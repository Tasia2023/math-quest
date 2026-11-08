-- MATH QUEST · Stage 1
-- Supabase PostgreSQL schema
-- Apply in Supabase Dashboard -> SQL Editor.
-- IMPORTANT: Student traffic must use Edge Functions. Never expose service_role keys.

create extension if not exists pgcrypto;

-- 1. Teacher accounts. A row is created for a teacher after their Auth account is approved.
create table if not exists public.teacher_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  created_at timestamptz not null default now()
);

-- 2. Teacher-owned groups.
create table if not exists public.student_groups (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teacher_profiles(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 3. Student profiles. Do not store children's full names unless truly necessary.
-- access_code_hash is a server-side hash; the original code is shown only once on creation.
create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.student_groups(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 80),
  access_code_hash text not null unique,
  code_hint text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4. Curriculum catalog.
create table if not exists public.topics (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  grade_level smallint,
  is_published boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.skills (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid not null references public.topics(id) on delete cascade,
  skill_code text not null,
  title text not null,
  sort_order smallint not null default 0,
  unique(topic_id, skill_code)
);

-- Questions and answer keys are server-side data.
-- Do not add an anon/authenticated SELECT policy for this table.
create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  skill_id uuid not null references public.skills(id) on delete cascade,
  external_code text not null,
  version integer not null default 1 check (version > 0),
  prompt jsonb not null,
  answer_key jsonb not null,
  explanation text,
  max_score numeric(6,2) not null default 1 check (max_score > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(external_code, version)
);

-- 5. Each completed or abandoned run is a separate attempt.
create table if not exists public.attempts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  topic_id uuid not null references public.topics(id),
  status text not null default 'in_progress'
    check (status in ('in_progress','completed','abandoned')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  total_score numeric(8,2),
  max_score numeric(8,2),
  percent_score numeric(5,2) check (percent_score between 0 and 100),
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  created_at timestamptz not null default now()
);

-- 6. One answer per question per attempt. Answers are immutable from the student browser;
-- Edge Functions validate and write them. Teachers can review them through RLS.
create table if not exists public.attempt_answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.attempts(id) on delete cascade,
  question_id uuid not null references public.questions(id),
  answer_value jsonb,
  is_correct boolean,
  score numeric(8,2),
  answered_at timestamptz not null default now(),
  unique(attempt_id, question_id)
);

-- 7. Skill snapshot per attempt, enabling historical progress charts.
create table if not exists public.attempt_skill_results (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.attempts(id) on delete cascade,
  skill_id uuid not null references public.skills(id),
  earned_score numeric(8,2) not null default 0,
  max_score numeric(8,2) not null default 0,
  percent_score numeric(5,2) check (percent_score between 0 and 100),
  unique(attempt_id, skill_id)
);

create index if not exists idx_groups_teacher on public.student_groups(teacher_id);
create index if not exists idx_students_group on public.students(group_id);
create index if not exists idx_attempts_student_date on public.attempts(student_id, started_at desc);
create index if not exists idx_answers_attempt on public.attempt_answers(attempt_id);
create index if not exists idx_skill_results_attempt on public.attempt_skill_results(attempt_id);

-- updated_at helper
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_groups_updated_at on public.student_groups;
create trigger trg_groups_updated_at before update on public.student_groups
for each row execute function public.set_updated_at();

drop trigger if exists trg_students_updated_at on public.students;
create trigger trg_students_updated_at before update on public.students
for each row execute function public.set_updated_at();

-- Enable Row Level Security on every table.
alter table public.teacher_profiles enable row level security;
alter table public.student_groups enable row level security;
alter table public.students enable row level security;
alter table public.topics enable row level security;
alter table public.skills enable row level security;
alter table public.questions enable row level security;
alter table public.attempts enable row level security;
alter table public.attempt_answers enable row level security;
alter table public.attempt_skill_results enable row level security;

-- Teacher profile: a signed-in teacher can read and create only their own profile.
drop policy if exists teacher_profile_select_own on public.teacher_profiles;
create policy teacher_profile_select_own on public.teacher_profiles
for select to authenticated using (id = auth.uid());

drop policy if exists teacher_profile_insert_own on public.teacher_profiles;
create policy teacher_profile_insert_own on public.teacher_profiles
for insert to authenticated with check (id = auth.uid());

drop policy if exists teacher_profile_update_own on public.teacher_profiles;
create policy teacher_profile_update_own on public.teacher_profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Groups: teacher can manage only their own groups.
drop policy if exists groups_teacher_all on public.student_groups;
create policy groups_teacher_all on public.student_groups
for all to authenticated
using (teacher_id = auth.uid())
with check (teacher_id = auth.uid());

-- Students: ownership is inherited through the group.
drop policy if exists students_teacher_all on public.students;
create policy students_teacher_all on public.students
for all to authenticated
using (
  exists (
    select 1 from public.student_groups g
    where g.id = students.group_id and g.teacher_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.student_groups g
    where g.id = students.group_id and g.teacher_id = auth.uid()
  )
);

-- Teacher can read the curriculum catalogue, but answer keys are not exposed to browser roles.
-- These catalog tables intentionally have no anon/authenticated policies.
-- Access them from trusted Edge Functions using the server-side service role.

-- Attempts and related records: teachers can read records only for their own students.
drop policy if exists attempts_teacher_select on public.attempts;
create policy attempts_teacher_select on public.attempts
for select to authenticated
using (
  exists (
    select 1
    from public.students s
    join public.student_groups g on g.id = s.group_id
    where s.id = attempts.student_id and g.teacher_id = auth.uid()
  )
);

drop policy if exists answers_teacher_select on public.attempt_answers;
create policy answers_teacher_select on public.attempt_answers
for select to authenticated
using (
  exists (
    select 1
    from public.attempts a
    join public.students s on s.id = a.student_id
    join public.student_groups g on g.id = s.group_id
    where a.id = attempt_answers.attempt_id and g.teacher_id = auth.uid()
  )
);

drop policy if exists skill_results_teacher_select on public.attempt_skill_results;
create policy skill_results_teacher_select on public.attempt_skill_results
for select to authenticated
using (
  exists (
    select 1
    from public.attempts a
    join public.students s on s.id = a.student_id
    join public.student_groups g on g.id = s.group_id
    where a.id = attempt_skill_results.attempt_id and g.teacher_id = auth.uid()
  )
);

-- No anon or authenticated policies are created for attempts/answers/skill results.
-- Students submit through Edge Functions only. Do not grant browser clients write access.

-- Seed the initial topic and six skills. Safe to re-run.
insert into public.topics (slug, title, grade_level, is_published)
values ('counting-to-20', 'Счёт в пределах 20', 1, true)
on conflict (slug) do update set title = excluded.title, grade_level = excluded.grade_level;

insert into public.skills (topic_id, skill_code, title, sort_order)
select t.id, v.skill_code, v.title, v.sort_order
from public.topics t
cross join (values
  ('S1','Сложение и вычитание',1),
  ('S2','Сравнение чисел и выражений',2),
  ('S3','Неизвестное число',3),
  ('S4','Текстовые задачи',4),
  ('S5','Работа с данными',5),
  ('S6','Счёт и последовательность чисел',6)
) as v(skill_code,title,sort_order)
where t.slug = 'counting-to-20'
on conflict (topic_id, skill_code) do update
set title = excluded.title, sort_order = excluded.sort_order;

-- Security note:
-- Code hashing, code verification, attempt creation, answer checking, score calculation,
-- and writes must be implemented in Supabase Edge Functions.
-- Use a slow password hash (Argon2id/bcrypt) in the Edge Function, not a plain SHA hash.
-- A short-lived student session token should be stored hashed and never expose the service role.
