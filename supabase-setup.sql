-- ===== إعداد قاعدة بيانات عجلة الحظ على Supabase =====
-- الصق الملف كاملًا في: SQL Editor ثم اضغط Run.
-- ملاحظة: سعر النقطة (10 ل.س) وتكلفة الدورة (10 نقاط) مكتوبان في الدوال أدناه
-- ويجب أن يطابقا RATE و COST في index.html إن غيّرتهما.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default 'لاعب',
  balance integer not null default 100 check (balance >= 0),
  is_admin boolean not null default false,
  joined timestamptz not null default now(),
  last_active timestamptz
);

create table public.requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('topup','withdraw')),
  syp integer not null check (syp > 0),
  points integer not null check (points > 0),
  tx text,
  acc text,
  status text not null default 'pending' check (status in ('pending','done','rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index requests_topup_tx_uniq on public.requests (upper(tx)) where type = 'topup';
create index requests_status_idx on public.requests (status, created_at desc);

-- إنشاء الملف الشخصي تلقائيًا عند تأكيد البريد
create or replace function public.handle_confirmed_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, lower(new.email),
          left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'لاعب'), 20))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_user_confirmed on auth.users;
create trigger on_user_confirmed
  after insert or update of email_confirmed_at on auth.users
  for each row when (new.email_confirmed_at is not null)
  execute function public.handle_confirmed_user();

-- الأمان: لا أحد يعدّل الجداول مباشرة، القراءة فقط وفق السياسات، والتعديل عبر الدوال
alter table public.profiles enable row level security;
alter table public.requests enable row level security;
revoke all on public.profiles, public.requests from anon, authenticated;
grant select on public.profiles, public.requests to authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

create policy "own or admin profile" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "own or admin requests" on public.requests
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create or replace function public.touch() returns void
language sql security definer set search_path = public as $$
  update public.profiles set last_active = now() where id = auth.uid();
$$;

-- تدوير العجلة على الخادم. عدّل القيم والأوزان كما تشاء (مجموع الأوزان 1000).
-- القيم بترتيب قطاعات العجلة. الأوزان الحالية تعيد نحو 87.5% من النقاط المصروفة.
create or replace function public.spin() returns json
language plpgsql security definer set search_path = public as $$
declare
  cost constant int := 10;
  vals int[] := array[100,0,20,50,10,10,200,0];
  wts  int[] := array[15,350,110,35,100,150,4,236];
  r int; cum int := 0; idx int := 0; i int; bal int; v int;
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولًا'; end if;
  select balance into bal from public.profiles where id = auth.uid() for update;
  if bal is null then raise exception 'الحساب غير موجود'; end if;
  if bal < cost then raise exception 'رصيدك لا يكفي للعب'; end if;
  r := floor(random() * 1000)::int;
  for i in 1..8 loop
    cum := cum + wts[i];
    if r < cum then idx := i - 1; exit; end if;
  end loop;
  v := vals[idx + 1];
  update public.profiles set balance = balance - cost + v, last_active = now()
    where id = auth.uid() returning balance into bal;
  return json_build_object('idx', idx, 'value', v, 'balance', bal);
end $$;

create or replace function public.request_topup(p_syp int, p_tx text) returns void
language plpgsql security definer set search_path = public as $$
declare t text := upper(trim(coalesce(p_tx, '')));
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولًا'; end if;
  if p_syp is null or p_syp < 10 or p_syp % 10 <> 0 then raise exception 'المبلغ يجب أن يكون من مضاعفات 10 ل.س'; end if;
  if t !~ '^[A-Z0-9-]{6,40}$' then raise exception 'رقم العملية غير صحيح'; end if;
  if exists (select 1 from public.requests where type = 'topup' and upper(tx) = t) then raise exception 'رقم العملية هذا مستخدم من قبل'; end if;
  if (select count(*) from public.requests where user_id = auth.uid() and type = 'topup' and status = 'pending') >= 5 then
    raise exception 'لديك طلبات شحن معلّقة كثيرة، انتظر المراجعة'; end if;
  insert into public.requests (user_id, type, syp, points, tx) values (auth.uid(), 'topup', p_syp, p_syp / 10, t);
end $$;

-- السحب: تُخصم النقاط فورًا (حجز) وتُعاد إن رُفض الطلب
create or replace function public.request_withdraw(p_points int, p_acc text) returns int
language plpgsql security definer set search_path = public as $$
declare bal int; a text := trim(coalesce(p_acc, ''));
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولًا'; end if;
  if p_points is null or p_points < 10 then raise exception 'أقل مبلغ للسحب 10 نقاط'; end if;
  if a !~ '^[A-Za-z0-9+ -]{6,40}$' then raise exception 'رقم حساب شام كاش غير صحيح'; end if;
  select balance into bal from public.profiles where id = auth.uid() for update;
  if bal is null or bal < p_points then raise exception 'رصيدك لا يكفي لهذا السحب'; end if;
  update public.profiles set balance = balance - p_points where id = auth.uid() returning balance into bal;
  insert into public.requests (user_id, type, syp, points, acc) values (auth.uid(), 'withdraw', p_points * 10, p_points, a);
  return bal;
end $$;

create or replace function public.admin_resolve(p_id bigint, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.requests%rowtype;
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
  select * into r from public.requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'الطلب غير موجود أو تمت معالجته'; end if;
  if r.type = 'topup' and p_ok then
    update public.profiles set balance = balance + r.points where id = r.user_id;
  elsif r.type = 'withdraw' and not p_ok then
    update public.profiles set balance = balance + r.points where id = r.user_id;
  end if;
  update public.requests set status = case when p_ok then 'done' else 'rejected' end, resolved_at = now() where id = p_id;
end $$;

create or replace function public.admin_stats() returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'غير مصرّح'; end if;
  return json_build_object(
    'users',  (select count(*) from public.profiles),
    'active', (select count(*) from public.profiles where last_active > now() - interval '24 hours'),
    'top',    (select count(*) from public.requests where type = 'topup' and status = 'pending'),
    'wd',     (select count(*) from public.requests where type = 'withdraw' and status = 'pending'));
end $$;

revoke execute on function public.touch(), public.spin(), public.request_topup(int, text),
  public.request_withdraw(int, text), public.admin_resolve(bigint, boolean),
  public.admin_stats(), public.is_admin() from public, anon;
grant execute on function public.touch(), public.spin(), public.request_topup(int, text),
  public.request_withdraw(int, text), public.admin_resolve(bigint, boolean),
  public.admin_stats(), public.is_admin() to authenticated;

-- ===== الخطوة الأخيرة (بعد أن تسجّل حسابك في الموقع) =====
-- اجعل حسابك مديرًا بتشغيل هذا السطر بعد تعديل البريد:
-- update public.profiles set is_admin = true where email = lower('بريدك@example.com');
