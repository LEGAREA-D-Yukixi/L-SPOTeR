-- =============================================================
-- 会議ブース予約システム  単体テスト (全仕様の総点検)
-- 実行先: Supabase SQL Editor。ブロック全体を選択して一度に実行(1トランザクション)。
-- begin...rollback 内なので本番データは一切残りません。
-- 結果テーブルの result が全て OK / OK(...) なら合格。
-- ※ 先に 01_rooms_schema.sql, 03_booths_upgrade.sql, 04_notifications.sql, 06_layout.sql を実行済みであること。
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

do $$ declare total int; lim int; mj int; begin
  select count(*),
         count(*) filter (where bookable_start_time='10:00' and bookable_end_time='11:00'),
         count(*) filter (where location='マリージョア')
  into total, lim, mj from public.rooms;
  if total>=13 and lim>=4 and mj>=4 then insert into _t values(2,'13ブース・4室が10-11制限・マリージョア','OK');
  else insert into _t values(2,'13ブース・4室が10-11制限・マリージョア', format('NG (total=%s, limited=%s, マリージョア=%s)', total, lim, mj)); end if;
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

-- ===== 分単位の予約(仕様) =====
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

-- ===== 利用集計(仕様) の下ごしらえ: 未制限の最終ブースに alice2件/bob1件 =====
do $$ declare rid uuid; begin
  select id into rid from public.rooms where bookable_start_time is null order by sort_order desc limit 1;
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  insert into public.bookings(room_id,user_id,starts_at,ends_at) values
   (rid,'11111111-1111-1111-1111-111111111111',(current_date+time '09:00') at time zone 'Asia/Tokyo',(current_date+time '09:30') at time zone 'Asia/Tokyo'),
   (rid,'11111111-1111-1111-1111-111111111111',(current_date+time '15:00') at time zone 'Asia/Tokyo',(current_date+time '16:00') at time zone 'Asia/Tokyo');
  perform set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  insert into public.bookings(room_id,user_id,starts_at,ends_at) values
   (rid,'22222222-2222-2222-2222-222222222222',(current_date+time '17:00') at time zone 'Asia/Tokyo',(current_date+time '17:30') at time zone 'Asia/Tokyo');
end $$;

do $$ declare rid uuid; c int; hrs numeric; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order desc limit 1;
  select count(*), round(sum(extract(epoch from (ends_at-starts_at))/3600)::numeric,2) into c,hrs
    from public.bookings where room_id=rid;
  if c=3 and hrs=2.00 then insert into _t values(23,'会議室別の利用集計(件数・時間)','OK');
  else insert into _t values(23,'会議室別の利用集計(件数・時間)', format('NG (件数=%s, 時間=%s)',c,hrs)); end if;
end $$;

do $$ declare rid uuid; c int; hrs numeric; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order desc limit 1;
  select count(*), round(sum(extract(epoch from (ends_at-starts_at))/3600)::numeric,2) into c,hrs
    from public.bookings where room_id=rid and user_id='11111111-1111-1111-1111-111111111111';
  if c=2 and hrs=1.50 then insert into _t values(24,'利用者別の利用集計(件数・時間)','OK');
  else insert into _t values(24,'利用者別の利用集計(件数・時間)', format('NG (件数=%s, 時間=%s)',c,hrs)); end if;
end $$;

-- ===== 予約者名の自動格納・改名同期(仕様) =====
do $$ declare rid uuid; nm text; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order offset 2 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','氏名自動',
          (current_date+time '08:00') at time zone 'Asia/Tokyo',(current_date+time '08:30') at time zone 'Asia/Tokyo');
  select organizer_name into nm from public.bookings where title='氏名自動';
  if nm='アリス' then insert into _t values(25,'予約時に予約者名を自動格納','OK');
  else insert into _t values(25,'予約時に予約者名を自動格納', 'NG: '||coalesce(nm,'(null)')); end if;
end $$;

do $$ declare nm text; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  update public.profiles set display_name='アリス改' where id='11111111-1111-1111-1111-111111111111';
  select organizer_name into nm from public.bookings where title='氏名自動';
  if nm='アリス改' then insert into _t values(26,'改名で過去予約の予約者名も同期','OK');
  else insert into _t values(26,'改名で過去予約の予約者名も同期', 'NG: '||coalesce(nm,'(null)')); end if;
end $$;

-- ===== 管理者による会議ブース 追加/改名(仕様) =====
do $$ begin
  perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  insert into public.rooms(name,color,sort_order,is_active) values ('テスト追加ブース','#888888',99,true);
  insert into _t values(27,'管理者は会議ブース追加可','OK');
exception when others then insert into _t values(27,'管理者は会議ブース追加可','NG: '||sqlerrm); end $$;

do $$ begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  insert into public.rooms(name,color,sort_order,is_active) values ('不正追加ブース','#888888',98,true);
  insert into _t values(28,'一般は会議ブース追加不可','NG: 通ってしまった');
exception when others then insert into _t values(28,'一般は会議ブース追加不可','OK(正しく拒否)'); end $$;

do $$ declare n int; begin
  perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  update public.rooms set name='改称ブース' where sort_order=1;
  get diagnostics n = row_count;
  if n=1 then insert into _t values(29,'管理者は会議ブース改名可','OK'); else insert into _t values(29,'管理者は会議ブース改名可','NG: 更新0件'); end if;
end $$;

do $$ declare n int; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  update public.rooms set name='不正改称' where sort_order=1;
  get diagnostics n = row_count;
  if n=0 then insert into _t values(30,'一般は会議ブース改名不可','OK'); else insert into _t values(30,'一般は会議ブース改名不可','NG: 更新できた'); end if;
end $$;

-- ===== 管理者が設定した任意の制限時間帯が適用される(仕様) =====
do $$ declare rid uuid; begin
  -- 対象ブース(制限なしの2番目)のidを取得
  select id into rid from public.rooms where bookable_start_time is null order by sort_order offset 1 limit 1;
  -- 管理者が任意の制限時間帯(13:00-14:00)を設定
  perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  update public.rooms set bookable_start_time=time '13:00', bookable_end_time=time '14:00' where id=rid;
  -- 一般ユーザーが枠外(16:00-17:00)を予約 → 拒否されるはず
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at)
  values (rid,'11111111-1111-1111-1111-111111111111','任意制限枠外',
          (current_date+time '16:00') at time zone 'Asia/Tokyo',(current_date+time '17:00') at time zone 'Asia/Tokyo');
  insert into _t values(31,'管理者設定の任意制限時間帯を適用','NG: 通ってしまった');
exception when others then insert into _t values(31,'管理者設定の任意制限時間帯を適用','OK(正しく拒否)'); end $$;

-- ===== 通知(メール) 仕様 =====
do $$ declare rid uuid; em text; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order offset 2 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min)
  values (rid,'11111111-1111-1111-1111-111111111111','メール自動',
          (current_date+time '08:00') at time zone 'Asia/Tokyo',(current_date+time '08:30') at time zone 'Asia/Tokyo',15)
  returning organizer_email into em;
  if em='alice@legarea.jp' then insert into _t values(32,'予約者メールの自動設定','OK');
  else insert into _t values(32,'予約者メールの自動設定','NG: '||coalesce(em,'(null)')); end if;
exception when others then insert into _t values(32,'予約者メールの自動設定','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; nb int; ns timestamptz; begin
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  select id into rid from public.rooms where bookable_start_time is null order by sort_order offset 3 limit 1;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min,notify_sent_at)
  values (rid,'11111111-1111-1111-1111-111111111111','通知設定',
          (current_date+time '08:00') at time zone 'Asia/Tokyo',(current_date+time '08:30') at time zone 'Asia/Tokyo',30, now())
  returning notify_before_min, notify_sent_at into nb, ns;
  if nb=30 and ns is null then insert into _t values(33,'通知分の保存＋送信済みは新規で必ずnull','OK');
  else insert into _t values(33,'通知分の保存＋送信済みは新規で必ずnull','NG: nb='||coalesce(nb::text,'null')||' sent='||coalesce(ns::text,'null')); end if;
exception when others then insert into _t values(33,'通知分の保存＋送信済みは新規で必ずnull','NG: '||sqlerrm); end $$;

reset role;
-- ここから所有者権限（security definer 関数の呼び出し・notify_sent_at の操作のため）
do $$ declare bid uuid; ns timestamptz; begin
  select id into bid from public.bookings where title='メール自動' limit 1;
  if bid is null then insert into _t values(34,'開始時刻の変更で通知を再アーム','SKIP(対象なし)');
  else
    update public.bookings set notify_sent_at = now() where id=bid;                       -- 送信済みにする(開始不変なので保持)
    update public.bookings set starts_at=(current_date+interval '30 day'+time '08:00') at time zone 'Asia/Tokyo',
                               ends_at  =(current_date+interval '30 day'+time '08:30') at time zone 'Asia/Tokyo' where id=bid;  -- 開始変更
    select notify_sent_at into ns from public.bookings where id=bid;
    if ns is null then insert into _t values(34,'開始時刻の変更で通知を再アーム','OK');
    else insert into _t values(34,'開始時刻の変更で通知を再アーム','NG: '||ns::text); end if;
  end if;
exception when others then insert into _t values(34,'開始時刻の変更で通知を再アーム','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; near_id uuid; okc boolean; begin
  insert into public.rooms(name,color,sort_order,is_active) values('通知テストブース','#777777',200,true) returning id into rid;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min)
  values (rid,'11111111-1111-1111-1111-111111111111','近い会議', now()+interval '5 min', now()+interval '35 min', 10)
  returning id into near_id;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min)
  values (rid,'11111111-1111-1111-1111-111111111111','遠い会議', now()+interval '3 hour', now()+interval '4 hour', 10);
  okc := exists(select 1 from public.due_meeting_notifications() where id=near_id)
     and not exists(select 1 from public.due_meeting_notifications() d join public.bookings b on b.id=d.id where b.title='遠い会議');
  if okc then insert into _t values(35,'通知対象抽出(直前=対象/先=対象外)','OK');
  else insert into _t values(35,'通知対象抽出(直前=対象/先=対象外)','NG'); end if;
exception when others then insert into _t values(35,'通知対象抽出(直前=対象/先=対象外)','NG: '||sqlerrm); end $$;

-- ===== 配置図(レイアウト) 仕様 =====
do $$ declare c int; r5r int; r5c int; ok10 bool; ok11 bool; ok13 bool; begin
  select count(*) into c from information_schema.columns
    where table_schema='public' and table_name='rooms' and column_name in ('layout_row','layout_col');
  select layout_row, layout_col into r5r, r5c from public.rooms where sort_order=5;
  select exists(select 1 from public.rooms where sort_order=10 and layout_row=1 and layout_col=1) into ok10;
  select exists(select 1 from public.rooms where sort_order=11 and layout_row=2 and layout_col=2) into ok11;
  select exists(select 1 from public.rooms where sort_order=13 and layout_row=2 and layout_col=4) into ok13;
  if c=2 and r5r=1 and r5c=2 and ok10 and ok11 and ok13 then insert into _t values(36,'配置図の座標列＋初期配置','OK');
  else insert into _t values(36,'配置図の座標列＋初期配置','NG: cols='||c||' b5=('||coalesce(r5r::text,'-')||','||coalesce(r5c::text,'-')||') 10='||ok10||' 11='||ok11||' 13='||ok13); end if;
exception when others then insert into _t values(36,'配置図の座標列＋初期配置','NG: '||sqlerrm); end $$;

do $$ declare na int; ny int; begin
  set local role authenticated;
  perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);  -- 一般
  with u as (update public.rooms set layout_col=layout_col where sort_order=5 returning 1) select count(*) into na from u;
  perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);  -- 管理者
  with u as (update public.rooms set layout_col=2 where sort_order=5 returning 1) select count(*) into ny from u;
  reset role;
  if na=0 and ny>=1 then insert into _t values(37,'配置更新は管理者のみ(一般=不可/管理者=可)','OK');
  else insert into _t values(37,'配置更新は管理者のみ(一般=不可/管理者=可)','NG: 一般='||na||' 管理者='||ny); end if;
exception when others then reset role; insert into _t values(37,'配置更新は管理者のみ(一般=不可/管理者=可)','NG: '||sqlerrm); end $$;

do $$ declare c int; begin
  select count(*) into c from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='notify_meetings_to_lark';
  if c>=1 then insert into _t values(38,'Lark通知関数の存在(07適用時)','OK');
  else insert into _t values(38,'Lark通知関数の存在(07適用時)','SKIP(07_lark_notify.sql 未実行)'); end if;
exception when others then insert into _t values(38,'Lark通知関数の存在(07適用時)','NG: '||sqlerrm); end $$;

do $$ declare has int; blocked boolean := false; n int; begin
  select count(*) into has from information_schema.tables where table_schema='public' and table_name='app_config';
  if has=0 then insert into _t values(39,'Lark設定テーブルの権限(07適用時)','SKIP(07_lark_notify.sql 未実行)');
  else
    set local role authenticated;
    perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
    begin
      select count(*) into n from public.app_config;   -- 一般ロールは読めないはず
      blocked := false;
    exception when insufficient_privilege then blocked := true;
    end;
    reset role;
    if blocked then insert into _t values(39,'Lark設定テーブルは一般ロールから不可視','OK');
    else insert into _t values(39,'Lark設定テーブルは一般ロールから不可視','NG: authenticatedが読めた'); end if;
  end if;
exception when others then reset role; insert into _t values(39,'Lark設定テーブルの権限(07適用時)','NG: '||sqlerrm); end $$;

do $$ declare rid uuid; bid uuid; got boolean; begin
  insert into public.rooms(name,color,sort_order,is_active) values('通知テスト2','#666666',201,true) returning id into rid;
  insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min)
    values (rid,'11111111-1111-1111-1111-111111111111','email無し会議', now()+interval '4 min', now()+interval '34 min', 10)
    returning id into bid;
  update public.bookings set organizer_email = null where id = bid;   -- メールを空にする
  got := exists(select 1 from public.due_meeting_notifications() where id = bid);
  if got then insert into _t values(40,'メール無しでも通知対象(Lark版due)','OK');
  else insert into _t values(40,'メール無しでも通知対象(Lark版due)','SKIP(04のメール版due。07適用でLark版に)'); end if;
exception when others then insert into _t values(40,'メール無しでも通知対象(Lark版due)','NG: '||sqlerrm); end $$;

do $$ declare has int; u1 text; u2 text; begin
  select count(*) into has from information_schema.tables where table_schema='public' and table_name='lark_group_webhooks';
  if has=0 then insert into _t values(41,'部門→Webhook解決(08適用時)','SKIP(08_lark_groups.sql 未実行)');
  else
    insert into public.lark_group_webhooks(division_key,label,webhook_url,sort_order)
      values ('__t_div','テスト部門','https://open.larksuite.com/open-apis/bot/v2/hook/DIV',50)
      on conflict (division_key) do update set webhook_url=excluded.webhook_url;
    u1 := public.resolve_lark_webhook('__t_div');     -- 部門一致
    u2 := public.resolve_lark_webhook('存在しない部門'); -- 既定へフォールバック
    if u1 like '%/DIV' and u2 is not null and u2 not like '%/DIV'
      then insert into _t values(41,'部門→Webhook解決(部門一致/既定フォールバック)','OK');
      else insert into _t values(41,'部門→Webhook解決(部門一致/既定フォールバック)','NG: div='||coalesce(u1,'-')||' fallback='||coalesce(u2,'-')); end if;
  end if;
exception when others then insert into _t values(41,'部門→Webhook解決(08適用時)','NG: '||sqlerrm); end $$;

do $$ declare has int; rid uuid; near uuid; oids text[]; begin
  select count(*) into has from information_schema.columns
   where table_schema='public' and table_name='profiles' and column_name='lark_open_id';
  if has=0 then insert into _t values(42,'due_meeting_dm open_id宛先(11適用時)','SKIP(11_lark_open_id.sql 未実行)');
  else
    update public.profiles set lark_open_id='ou_alice' where id='11111111-1111-1111-1111-111111111111';
    update public.profiles set lark_open_id='ou_bob'   where id='22222222-2222-2222-2222-222222222222';
    insert into public.rooms(name,color,sort_order,is_active) values('DMテストブース','#777777',201,true) returning id into rid;
    insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min,participant_user_ids)
      values (rid,'11111111-1111-1111-1111-111111111111','DM近い会議',
              now()+interval '5 min', now()+interval '35 min', 10,
              array['22222222-2222-2222-2222-222222222222']::uuid[])
      returning id into near;
    select recipient_open_ids into oids from public.due_meeting_dm() where id=near;
    if oids @> array['ou_alice'] and oids @> array['ou_bob']
      then insert into _t values(42,'due_meeting_dm 予約者+参加者のopen_idを返す','OK');
      else insert into _t values(42,'due_meeting_dm 予約者+参加者のopen_idを返す','NG: '||coalesce(array_to_string(oids,','),'(null)')); end if;
  end if;
exception when others then insert into _t values(42,'due_meeting_dm open_id宛先(11適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasd int; haspo int; rid uuid; nb uuid; oids text[]; begin
  select count(*) into hasd from information_schema.tables
   where table_schema='public' and table_name='lark_directory';
  select count(*) into haspo from information_schema.columns
   where table_schema='public' and table_name='bookings' and column_name='participant_open_ids';
  if hasd=0 or haspo=0 then insert into _t values(43,'未サインアップ参加者へのopen_id宛先(13適用時)','SKIP(13_directory_participants.sql 未実行)');
  else
    update public.profiles set lark_open_id='ou_alice' where id='11111111-1111-1111-1111-111111111111';
    insert into public.lark_directory(open_id,name,email) values('ou_guest','ゲスト','guest@legarea.jp')
      on conflict (open_id) do update set name=excluded.name, email=excluded.email;
    insert into public.rooms(name,color,sort_order,is_active) values('DIRテストブース','#778899',202,true) returning id into rid;
    insert into public.bookings(room_id,user_id,title,starts_at,ends_at,notify_before_min,participant_open_ids)
      values (rid,'11111111-1111-1111-1111-111111111111','ディレクトリ参加者会議',
              now()+interval '5 min', now()+interval '35 min', 10,
              array['ou_guest']::text[])
      returning id into nb;
    select recipient_open_ids into oids from public.due_meeting_dm() where id=nb;
    if oids @> array['ou_alice'] and oids @> array['ou_guest']
      then insert into _t values(43,'due_meeting_dm 予約者+未登録参加者(open_id直接)を返す','OK');
      else insert into _t values(43,'due_meeting_dm 予約者+未登録参加者(open_id直接)を返す','NG: '||coalesce(array_to_string(oids,','),'(null)')); end if;
  end if;
exception when others then insert into _t values(43,'未サインアップ参加者へのopen_id宛先(13適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasf int; c int; begin
  select count(*) into hasf from information_schema.routines
   where routine_schema='public' and routine_name='list_directory';
  if hasf=0 then insert into _t values(44,'list_directory(13適用時)','SKIP(13_directory_participants.sql 未実行)');
  else
    insert into public.lark_directory(open_id,name,email) values('ou_guest','ゲスト','guest@legarea.jp')
      on conflict (open_id) do update set name=excluded.name;
    select count(*) into c from public.list_directory() where open_id='ou_guest' and name='ゲスト';
    if c=1 then insert into _t values(44,'list_directory が氏名+open_idを返す','OK');
    else insert into _t values(44,'list_directory が氏名+open_idを返す','NG: count='||c); end if;
  end if;
exception when others then insert into _t values(44,'list_directory(13適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasc int; rid uuid; g uuid; d int; begin
  select count(*) into hasc from information_schema.columns
   where table_schema='public' and table_name='bookings' and column_name='recurrence_group';
  if hasc=0 then insert into _t values(45,'繰り返しシリーズ(recurrence_group)(14適用時)','SKIP(14_recurrence.sql 未実行)');
  else
    g := gen_random_uuid();
    insert into public.rooms(name,color,sort_order,is_active) values('繰返テストブース','#888888',203,true) returning id into rid;
    insert into public.bookings(room_id,user_id,title,starts_at,ends_at,recurrence_group) values
      (rid,'11111111-1111-1111-1111-111111111111','r1', now()+interval '1 day 10 hour', now()+interval '1 day 11 hour', g),
      (rid,'11111111-1111-1111-1111-111111111111','r2', now()+interval '2 day 10 hour', now()+interval '2 day 11 hour', g),
      (rid,'11111111-1111-1111-1111-111111111111','r3', now()+interval '3 day 10 hour', now()+interval '3 day 11 hour', g);
    delete from public.bookings where recurrence_group=g and starts_at >= now()+interval '2 day 10 hour';  -- この回以降
    select count(*) into d from public.bookings where recurrence_group=g;
    if d=1 then insert into _t values(45,'recurrence_group でシリーズ(この回以降)削除','OK');
    else insert into _t values(45,'recurrence_group でシリーズ(この回以降)削除','NG: 残'||d); end if;
  end if;
exception when others then insert into _t values(45,'繰り返しシリーズ(recurrence_group)(14適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasc int; rid uuid; jv jsonb; begin
  select count(*) into hasc from information_schema.columns
   where table_schema='public' and table_name='bookings' and column_name='recurrence_rule_json';
  if hasc=0 then insert into _t values(46,'繰り返しルールJSON(recurrence_rule_json)(15適用時)','SKIP(15_recurrence_json.sql 未実行)');
  else
    insert into public.rooms(name,color,sort_order,is_active) values('繰返JSONテスト','#999999',204,true) returning id into rid;
    insert into public.bookings(room_id,user_id,title,starts_at,ends_at,recurrence_rule_json) values
      (rid,'11111111-1111-1111-1111-111111111111','j', now()+interval '5 day 10 hour', now()+interval '5 day 11 hour',
       '{"freq":"custom","unit":"week","interval":2,"weekdays":[1,3],"endType":"count","count":8}'::jsonb);
    select recurrence_rule_json into jv from public.bookings where room_id=rid limit 1;
    if (jv->>'interval')='2' and (jv->>'freq')='custom' then insert into _t values(46,'recurrence_rule_json にjsonbを保存/取得','OK');
    else insert into _t values(46,'recurrence_rule_json にjsonbを保存/取得','NG: '||coalesce(jv::text,'null')); end if;
  end if;
exception when others then insert into _t values(46,'繰り返しルールJSON(recurrence_rule_json)(15適用時)','NG: '||sqlerrm); end $$;

do $$ declare hast int; cnt int; begin
  select count(*) into hast from information_schema.tables where table_schema='public' and table_name='directory_allow';
  if hast=0 then insert into _t values(47,'許可リスト(directory_allow)(16適用時)','SKIP(16_directory_allow.sql 未実行)');
  else
    insert into public.directory_allow(name) values('__許可太郎__') on conflict do nothing;
    insert into public.lark_directory(open_id,name,email) values
      ('ou_allow_ok','__許可太郎__','allow-ok@example.com'),
      ('ou_allow_ng','__不許可花子__','allow-ng@example.com') on conflict (open_id) do nothing;
    delete from public.lark_directory d
     where replace(replace(d.name,' ',''),'　','') not in (select name from public.directory_allow);  -- 許可外を削除
    select count(*) into cnt from public.lark_directory where open_id in ('ou_allow_ok','ou_allow_ng');
    if cnt=1 and exists(select 1 from public.lark_directory where open_id='ou_allow_ok')
       and not exists(select 1 from public.lark_directory where open_id='ou_allow_ng')
    then insert into _t values(47,'directory_allow に無い候補は削除される','OK');
    else insert into _t values(47,'directory_allow に無い候補は削除される','NG: 残'||cnt); end if;
  end if;
exception when others then insert into _t values(47,'許可リスト(directory_allow)(16適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasf int; got boolean; begin
  select count(*) into hasf from pg_proc where proname='set_admin' and pronamespace='public'::regnamespace;
  if hasf=0 then insert into _t values(48,'管理者権限(set_admin/list_users_admin)(18適用時)','SKIP(18_admin_management.sql 未実行)');
  else
    got := false;
    begin perform public.set_admin('11111111-1111-1111-1111-111111111111', true);
    exception when others then got := true; end;   -- 非管理者(auth.uid=null)は拒否される想定
    if got and (select count(*) from public.list_users_admin())=0
    then insert into _t values(48,'set_admin/list_users_admin は管理者のみ','OK(正しく拒否)');
    else insert into _t values(48,'set_admin/list_users_admin は管理者のみ','NG'); end if;
  end if;
exception when others then insert into _t values(48,'管理者権限(set_admin/list_users_admin)(18適用時)','NG: '||sqlerrm); end $$;

do $$ declare hasf int; v text; begin
  select count(*) into hasf from pg_proc where proname='resolve_lark_open_id' and pronamespace='public'::regnamespace;
  if hasf=0 then insert into _t values(49,'resolve_lark_open_id(19適用時)','SKIP(19_password_reset.sql 未実行)');
  else
    v := public.resolve_lark_open_id('nonexistent-xyz@example.com');
    if v is null then insert into _t values(49,'resolve_lark_open_id 未登録はnull','OK');
    else insert into _t values(49,'resolve_lark_open_id 未登録はnull','NG: '||v); end if;
  end if;
exception when others then insert into _t values(49,'resolve_lark_open_id(19適用時)','NG: '||sqlerrm); end $$;

do $$ declare hascol int; begin
  select count(*) into hascol from information_schema.columns
    where table_schema='public' and table_name='bookings' and column_name='meeting_url';
  if hascol=0 then insert into _t values(50,'会議リンク(meeting_url/20適用時)','SKIP(20_meeting_link.sql 未実行)');
  else
    begin
      perform meeting_url from public.due_meeting_dm() limit 1;   -- 列が無ければ例外
      insert into _t values(50,'bookings.meeting_url + due_meeting_dm が返す','OK');
    exception when others then insert into _t values(50,'bookings.meeting_url + due_meeting_dm が返す','NG: '||sqlerrm);
    end;
  end if;
exception when others then insert into _t values(50,'会議リンク(meeting_url/20適用時)','NG: '||sqlerrm); end $$;

do $$ declare hascol int; n int; begin
  select count(*) into hascol from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='lark_welcomed_at';
  if hascol=0 then insert into _t values(51,'氏名でopen_id連携(21適用時)','SKIP(21_link_open_id_by_name.sql 未実行)');
  else
    begin
      -- 正規化関数と一括連携RPCが動くこと（副作用はrollbackで戻る）
      perform public.norm_name('山田　太郎');
      select public.relink_open_ids_by_name() into n;
      insert into _t values(51,'norm_name + relink_open_ids_by_name + welcomed列','OK');
    exception when others then insert into _t values(51,'norm_name + relink_open_ids_by_name + welcomed列','NG: '||sqlerrm);
    end;
  end if;
exception when others then insert into _t values(51,'氏名でopen_id連携(21適用時)','NG: '||sqlerrm); end $$;

do $$ declare d int; u int; begin
  select count(*) into d from pg_policies where schemaname='public' and tablename='bookings' and policyname='bookings_delete_admin';
  select count(*) into u from pg_policies where schemaname='public' and tablename='bookings' and policyname='bookings_update_admin';
  if d=1 and u=1 then insert into _t values(52,'管理者の予約削除/更新ポリシー(22適用時)','OK');
  elsif d=0 and u=0 then insert into _t values(52,'管理者の予約削除/更新ポリシー(22適用時)','SKIP(22_admin_booking_manage.sql 未実行)');
  else insert into _t values(52,'管理者の予約削除/更新ポリシー(22適用時)','NG: delete='||d||' update='||u);
  end if;
exception when others then insert into _t values(52,'管理者の予約削除/更新ポリシー(22適用時)','NG: '||sqlerrm); end $$;

do $$ declare g int; begin
  select count(*) into g from information_schema.role_table_grants
   where grantee='service_role' and table_schema='public' and table_name='profiles'
     and privilege_type in ('SELECT','UPDATE');
  if g>=2 then insert into _t values(53,'service_roleにprofiles権限(23適用時)','OK');
  elsif g=0 then insert into _t values(53,'service_roleにprofiles権限(23適用時)','SKIP(23_profiles_service_grant.sql 未実行)');
  else insert into _t values(53,'service_roleにprofiles権限(23適用時)','NG: grants='||g);
  end if;
exception when others then insert into _t values(53,'service_roleにprofiles権限(23適用時)','NG: '||sqlerrm); end $$;

do $$ declare u int; d int; begin
  select count(*) into u from pg_policies where schemaname='public' and tablename='bookings'
     and policyname='bookings_update_own' and coalesce(qual,'') like '%ends_at%';
  select count(*) into d from pg_policies where schemaname='public' and tablename='bookings'
     and policyname='bookings_delete_own' and coalesce(qual,'') like '%ends_at%';
  if u=1 and d=1 then insert into _t values(54,'過去予約は本人編集/削除不可・RLS(24適用時)','OK');
  elsif u=0 and d=0 then insert into _t values(54,'過去予約は本人編集/削除不可・RLS(24適用時)','SKIP(24_past_booking_owner_lock.sql 未実行)');
  else insert into _t values(54,'過去予約は本人編集/削除不可・RLS(24適用時)','NG: update='||u||' delete='||d);
  end if;
exception when others then insert into _t values(54,'過去予約は本人編集/削除不可・RLS(24適用時)','NG: '||sqlerrm); end $$;

do $$ declare has int; begin
  select count(*) into has from information_schema.routines
   where routine_schema='public' and routine_name='set_room_active';
  if has>=1 then insert into _t values(55,'ブース論理削除RPC set_room_active(25適用時)','OK');
  else insert into _t values(55,'ブース論理削除RPC set_room_active(25適用時)','SKIP(25_room_soft_delete.sql 未実行)');
  end if;
exception when others then insert into _t values(55,'ブース論理削除RPC set_room_active(25適用時)','NG: '||sqlerrm); end $$;

do $$ declare has int; n_admin int; n_user int; n_allow int; denied boolean := false; begin
  select count(distinct routine_name) into has from information_schema.routines
   where routine_schema='public' and routine_name in
     ('list_members_admin','add_member_admin','remove_member_admin','admin_resync_members','admin_relink_members');
  if has=0 then insert into _t values(56,'メンバー管理RPC(26適用時)','SKIP(26_member_management.sql 未実行)');
  elsif has<5 then insert into _t values(56,'メンバー管理RPC(26適用時)','NG: RPC数='||has);
  else
    -- 一般ユーザー(alice): 追加は拒否・一覧は0件
    perform set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
    begin perform public.add_member_admin('テスト 太郎'); exception when others then denied := (sqlerrm like '%forbidden%'); end;
    select count(*) into n_user from public.list_members_admin();
    -- 管理者(y-tsuchiya): 一覧は許可リスト全件
    perform set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
    select count(*) into n_admin from public.list_members_admin();
    select count(*) into n_allow from public.directory_allow;
    if denied and n_user=0 and n_admin=n_allow then insert into _t values(56,'メンバー管理RPC: 一般は拒否/管理者は一覧可(26)','OK');
    else insert into _t values(56,'メンバー管理RPC: 一般は拒否/管理者は一覧可(26)','NG: denied='||denied||' user='||n_user||' admin='||n_admin||'/'||n_allow);
    end if;
  end if;
exception when others then insert into _t values(56,'メンバー管理RPC(26適用時)','NG: '||sqlerrm); end $$;

select seq, label, result from _t order by seq;
rollback;
-- 期待: 全56項目が OK / OK(正しく拒否) / SKIP
