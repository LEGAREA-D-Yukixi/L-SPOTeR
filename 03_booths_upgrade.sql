-- =============================================================
-- 03_booths_upgrade.sql  (一度だけ実行する移行スクリプト)
-- 目的:
--   1) rooms に location、bookings に organizer_name を追加
--   2) 予約時に予約者名を自動格納するトリガー
--   3) 氏名変更時に過去予約の予約者名も同期するトリガー(集計を同一ユーザーで維持)
--   4) 管理者のみ会議ブースの追加・改名を許可する RLS
--   5) 既存10室を会議ブース①〜⑩へ改称し、会議ブース⑪⑫⑬を追加
--      (10〜13 = 場所「マリージョア」・10:00〜11:00 のみ)
-- 既存の予約データは保持されます(部屋の id は変更しないため)。
-- Supabase SQL Editor に貼り付けて実行してください。
-- =============================================================

-- 1) カラム追加 -------------------------------------------------
alter table public.rooms    add column if not exists location text;
alter table public.bookings add column if not exists organizer_name text;

-- 2) 予約者名の自動格納 (INSERT時に user_id の氏名を入れる) --------
create or replace function public.set_booking_organizer_name()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.organizer_name := (select display_name from public.profiles where id = new.user_id);
  return new;
end $$;

drop trigger if exists set_booking_organizer_name_trg on public.bookings;
create trigger set_booking_organizer_name_trg
  before insert on public.bookings
  for each row execute function public.set_booking_organizer_name();

-- 3) 氏名変更を過去予約へ同期 -----------------------------------
create or replace function public.sync_organizer_name()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.bookings set organizer_name = new.display_name where user_id = new.id;
  return new;
end $$;

drop trigger if exists sync_organizer_name_trg on public.profiles;
create trigger sync_organizer_name_trg
  after update of display_name on public.profiles
  for each row when (old.display_name is distinct from new.display_name)
  execute function public.sync_organizer_name();

-- 既存予約の予約者名を埋める(初回のみ) ---------------------------
update public.bookings b
   set organizer_name = p.display_name
  from public.profiles p
 where p.id = b.user_id and b.organizer_name is null;

-- 4) 管理者のみ 会議ブース 追加/改名可 (RLS) ---------------------
grant insert, update on public.rooms to authenticated;

drop policy if exists rooms_admin_insert on public.rooms;
create policy rooms_admin_insert on public.rooms
  for insert to authenticated with check (public.is_admin());

drop policy if exists rooms_admin_update on public.rooms;
create policy rooms_admin_update on public.rooms
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- 5) 会議ブース13個化 -------------------------------------------
-- 5-1) 既存10室(会議室N)を会議ブース①〜⑩へ。10室は場所/時間帯も設定。
--      ※ 既に改称済み/カスタム名の部屋は変更しません(再実行安全)。
update public.rooms set
  name = case sort_order
    when 1 then '会議ブース①' when 2 then '会議ブース②' when 3 then '会議ブース③'
    when 4 then '会議ブース④' when 5 then '会議ブース⑤' when 6 then '会議ブース⑥'
    when 7 then '会議ブース⑦' when 8 then '会議ブース⑧' when 9 then '会議ブース⑨'
    when 10 then '会議ブース⑩' else name end,
  location            = case when sort_order between 10 and 13 then 'マリージョア' else null end,
  bookable_start_time = case when sort_order between 10 and 13 then time '10:00' else null end,
  bookable_end_time   = case when sort_order between 10 and 13 then time '11:00' else null end
where name like '会議室%';

-- 5-2) 会議ブース⑪⑫⑬ を追加(なければ)。
insert into public.rooms(name, color, sort_order, bookable_start_time, bookable_end_time, location, is_active)
select v.name, v.color, v.so, time '10:00', time '11:00', 'マリージョア', true
from (values
  ('会議ブース⑪','#f59e0b',11),
  ('会議ブース⑫','#f59e0b',12),
  ('会議ブース⑬','#f59e0b',13)
) as v(name,color,so)
where not exists (select 1 from public.rooms r where r.sort_order = v.so);

-- 確認用
select sort_order, name, location, bookable_start_time, bookable_end_time
from public.rooms order by sort_order;
