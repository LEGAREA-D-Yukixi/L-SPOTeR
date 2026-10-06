-- =============================================================
-- 26_member_management.sql   （SQL Editor で実行 / 冪等）
--
-- メンバー（許可リスト directory_allow）を画面から管理するための管理者RPC。
--   ・list_members_admin()        … 一覧＋状態（Larkで検出済み / 通知連携済み）
--   ・add_member_admin(name)      … 追加 → Lark同期を起動
--   ・remove_member_admin(name)   … 削除 → 参加者候補(lark_directory)からも即時除外
--   ・admin_resync_members()      … Lark同期を手動起動
--   ・admin_relink_members()      … 未連携アカウントを氏名で一括連携
-- いずれも is_admin() でない呼び出しは 'forbidden'（一覧は空）。
--
-- 削除してもアカウント(profiles)・open_id連携・過去の予約は残る（参加者候補から外れるだけ）。
-- 許可リストが空になると同期が全員を取り込む仕様のため、最後の1人は削除不可。
--
-- 前提: 12（trigger_lark_sync）・13（lark_directory）・16（directory_allow）・
--       21（norm_name / relink_open_ids_by_name）実行済み。
-- =============================================================

-- 0) 既存行の氏名を空白除去形に揃える（手動 insert で空白入りが混ざっていても重複しないように）
delete from public.directory_allow a
 where a.name <> public.norm_name(a.name)
   and exists (select 1 from public.directory_allow b where b.name = public.norm_name(a.name));
update public.directory_allow set name = public.norm_name(name) where name <> public.norm_name(name);

-- 1) 一覧（管理者のみ。非管理者は0件）
create or replace function public.list_members_admin()
returns table(name text, in_directory boolean, linked boolean, added_at timestamptz)
language sql security definer set search_path = public stable as $$
  select a.name,
    exists (select 1 from public.lark_directory d
             where public.norm_name(d.name) = a.name) as in_directory,
    exists (select 1 from public.lark_directory d
              join public.profiles p on p.lark_open_id = d.open_id
             where public.norm_name(d.name) = a.name) as linked,
    a.added_at
  from public.directory_allow a
  where public.is_admin()
  order by a.name;
$$;

-- 2) 追加（空白除去して格納）→ 同期起動
create or replace function public.add_member_admin(p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  v := public.norm_name(p_name);
  if v = '' then raise exception 'empty'; end if;
  insert into public.directory_allow(name) values (v) on conflict (name) do nothing;
  perform public.trigger_lark_sync();          -- Larkから取り直し（非同期・数秒）
  return v;
end $$;

-- 3) 削除 → 参加者候補からも即時除外
create or replace function public.remove_member_admin(p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v text; n int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  v := public.norm_name(p_name);
  if (select count(*) from public.directory_allow) <= 1 then raise exception 'last'; end if;
  delete from public.directory_allow where public.norm_name(name) = v;
  get diagnostics n = row_count;
  delete from public.lark_directory where public.norm_name(name) = v;
  return n > 0;
end $$;

-- 4) 手動同期
create or replace function public.admin_resync_members()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  perform public.trigger_lark_sync();
end $$;

-- 5) 未連携アカウントを氏名で一括連携（同期完了後に画面から呼ぶ）
create or replace function public.admin_relink_members()
returns int language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return public.relink_open_ids_by_name();
end $$;

revoke all on function public.list_members_admin()        from public, anon;
revoke all on function public.add_member_admin(text)      from public, anon;
revoke all on function public.remove_member_admin(text)   from public, anon;
revoke all on function public.admin_resync_members()      from public, anon;
revoke all on function public.admin_relink_members()      from public, anon;
grant execute on function public.list_members_admin()      to authenticated;
grant execute on function public.add_member_admin(text)    to authenticated;
grant execute on function public.remove_member_admin(text) to authenticated;
grant execute on function public.admin_resync_members()    to authenticated;
grant execute on function public.admin_relink_members()    to authenticated;

-- 確認（管理者アカウントでログイン中のアプリから使う想定。SQL Editorでは is_admin() が false になり一覧は0件）:
--   select count(*) from public.directory_allow;
