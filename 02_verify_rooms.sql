-- =============================================================
-- 会議室予約システム  単体テスト (全仕様の総点検)
-- 実行先: Supabase SQL Editor。ブロック全体を選択して一度に実行(1トランザクション)。
-- begin...rollback 内なので本番データは一切残りません。
-- 結果テーブルの result が全て OK / OK(...) なら合格。
-- ※ 先に 01_rooms_schema.sql を実行済みであること。
-- =============================================================
begin;
create temp table _t(seq int, label text, result text) on commit drop;
grant insert, select on _t to authenticated;

-- ===== Part 1: 静的チェック =====
do $$ begin
  if (select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname in ('profiles','admin_emails','rooms','bookings'))
  then insert into _t values(1,'RLSが4テーブルで有効','OK');
  else insert into _t values(1,'RLSが4テーブルで有効','NG'); end if;
end $$;

do $$ declare total int; lim int; begin
  select count(*), count(*) filter (where bookable_start_time='10:00' and bookable_end_time='11:00')
  into total, lim from public.rooms;
  if total=10 and lim=4 then insert into _t values(2,'10室投入・4室が10-11制限','OK');
  else insert into _t values(2,'10室投入・4室が10-11制限', format('NG (total=%s, limited=%s)', total, lim)); end if;
end $$;

do $$ begin
  if exists(select 1 from pg_constraint where conname='bookings_no_overlap')
  then insert into _t values(3,'重複防止の排他制約','OK'); else insert into _t values(3,'重複防止の排他制約','NG'); end if;
end $$;

do $$ begin
  if exists(select 1 from pg_extension where extname='btree_gist')
  then insert into _t values(4,'btree_gist 拡張','OK'); else insert into _t values(4,'btree_gist 拡張','NG'); end if;
end $$;

do $$ begin
  if exists(select 1 from pg_trigger where tgname='enforce_signup_domain_trg')
  then insert into _t values(5,'ドメイン制限トリガー存在','OK'); else insert into _t values(5,'ドメイン制限トリガー存在','NG'); end if;
end $$;

do $$ begin
  if exists(select 1 from public.admin_emails where email='y-tsuchiya@legarea.jp')
  then insert into _t values(6,'管理者メール登録済み','OK'); else insert into _t values(6,'管理者メール登録済み','NG'); end if;
end $$;

-- ===== テストユーザー作成 (@legarea.jp) =====
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at) values
 ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','alice@legarea.jp','x',now(),now()),
 ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','bob@legarea.jp','x',now(),now()),
 ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','y-tsuchiya@legarea.jp','x',now(),now());

do $$ begin
  if (select is_admin from public.profiles where id='33333333-3333-3333-3333-333333333333')
  then insert into _t values(7,'管理者の自動付与(y-tsuchiya)','OK'); else insert into _t values(7,'管理者の自動付与(y-tsuchiya)','NG'); end if;
end $$;

do $$ begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999','authenticated','authenticated','outsider@gmail.com','x',now(),now());
  insert into _t values(8,'社外ドメインの登録拒否','NG: 通ってしまった');
exception when others then insert into _t values(8,'社外ドメインの登録拒否','OK(正しく拒否)'); end $$;

-- ===== Part 2: 動作チェック (authenticated) =====
set local role authenticated;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','alice予約',
          (current_date+time '14:00') at time zone 'Asia/Tokyo',(current_date+time '15:00') at time zone 'Asia/Tokyo');
  insert into _t values(9,'本人予約の作成','OK');
exception when others then insert into _t values(9,'本人予約の作成','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'22222222-2222-2222-2222-222222222222','なりすまし',
          (current_date+time '16:00') at time zone 'Asia/Tokyo',(current_date+time '17:00') at time zone 'Asia/Tokyo');
  insert into _t values(10,'他人名義の予約を拒否','NG: 通ってしまった');
exception when others then insert into _t values(10,'他人名義の予約を拒否','OK(正しく拒否)'); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'22222222-2222-2222-2222-222222222222','重複',
          (current_date+time '14:30') at time zone 'Asia/Tokyo',(current_date+time '15:30') at time zone 'Asia/Tokyo');
  insert into _t values(11,'重複予約のブロック','NG: 通ってしまった');
exception when others then insert into _t values(11,'重複予約のブロック','OK(正しく拒否)'); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time='10:00' order by sort_order limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','枠外',
          (current_date+time '14:00') at time zone 'Asia/Tokyo',(current_date+time '15:00') at time zone 'Asia/Tokyo');
  insert into _t values(12,'時間帯制限(枠外)のブロック','NG: 通ってしまった');
exception when others then insert into _t values(12,'時間帯制限(枠外)のブロック','OK(正しく拒否)'); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time='10:00' order by sort_order limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','枠内',
          (current_date+time '10:15') at time zone 'Asia/Tokyo',(current_date+time '10:45') at time zone 'Asia/Tokyo');
  insert into _t values(13,'時間帯制限(枠内)の許可','OK');
exception when others then insert into _t values(13,'時間帯制限(枠内)の許可','NG: '||sqlerrm); end $$;

do $$ declare n int; begin
  perform set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  update public.bookings set title='改ざん' where title='alice予約';
  get diagnostics n = row_count;
  if n=0 then insert into _t values(14,'他人の予約は編集不可','OK'); else insert into _t values(14,'他人の予約は編集不可','NG: 更新できた'); end if;
end $$;

do $$ begin
  perform set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  delete from public.bookings where title='alice予約';
  if exists(select 1 from public.bookings where title='alice予約')
  then insert into _t values(15,'他人の予約は削除不可(一般)','OK'); else insert into _t values(15,'他人の予約は削除不可(一般)','NG: 削除できた'); end if;
end $$;

do $$ begin
  perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  delete from public.bookings where title='alice予約';
  if not exists(select 1 from public.bookings where title='alice予約')
  then insert into _t values(16,'管理者は他人の予約を削除可','OK'); else insert into _t values(16,'管理者は他人の予約を削除可','NG: 消えていない'); end if;
end $$;

do $$ begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  update public.profiles set is_admin=true where id='11111111-1111-1111-1111-111111111111';
  if (select is_admin from public.profiles where id='11111111-1111-1111-1111-111111111111')=false
  then insert into _t values(17,'権限昇格の防止','OK'); else insert into _t values(17,'権限昇格の防止','NG: 昇格できた'); end if;
end $$;

do $$ begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  update public.profiles set display_name='アリス' where id='11111111-1111-1111-1111-111111111111';
  if (select display_name from public.profiles where id='11111111-1111-1111-1111-111111111111')='アリス'
  then insert into _t values(18,'自分の氏名変更','OK'); else insert into _t values(18,'自分の氏名変更','NG'); end if;
end $$;

do $$ declare n int; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  update public.profiles set display_name='改ざん' where id='22222222-2222-2222-2222-222222222222';
  get diagnostics n = row_count;
  if n=0 then insert into _t values(19,'他人の氏名は変更不可','OK'); else insert into _t values(19,'他人の氏名は変更不可','NG: 変更できた'); end if;
end $$;

-- ===== 分単位の予約(追加仕様) =====
do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order offset 1 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','分単位',
          (current_date+time '13:07') at time zone 'Asia/Tokyo',(current_date+time '13:53') at time zone 'Asia/Tokyo');
  insert into _t values(20,'分単位の予約(制限なし)','OK');
exception when others then insert into _t values(20,'分単位の予約(制限なし)','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time='10:00' order by sort_order offset 1 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','分単位枠内',
          (current_date+time '10:05') at time zone 'Asia/Tokyo',(current_date+time '10:55') at time zone 'Asia/Tokyo');
  insert into _t values(21,'分単位の予約(限定室・枠内)','OK');
exception when others then insert into _t values(21,'分単位の予約(限定室・枠内)','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time='10:00' order by sort_order offset 2 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','枠超過',
          (current_date+time '10:30') at time zone 'Asia/Tokyo',(current_date+time '11:05') at time zone 'Asia/Tokyo');
  insert into _t values(22,'分単位でも枠超過は拒否','NG: 通ってしまった');
exception when others then insert into _t values(22,'分単位でも枠超過は拒否','OK(正しく拒否)'); end $$;

reset role;
select seq, label, result from _t order by seq;
rollback;
-- 期待: 全22項目が OK / OK(正しく拒否)
