// =============================================================
// 会議ブース予約 フロントエンド単体テスト / デグレ防止テスト
//   実行: node test_frontend.mjs   （ローカル開発用。リポジトリには不要）
//   index.html 内の実コードをVMで読み込み、純関数を直接検証します。
//   併せて、狭幅レイアウト崩れバグの再発防止(静的ガード)も検査します。
// =============================================================
import fs from "fs";
import vm from "vm";
import path from "path";
import { fileURLToPath } from "url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(HERE, "index.html");
const html = fs.readFileSync(INDEX, "utf8");

// ---- インラインの<script>本体を取り出す（src付きは除外） ----
const inline = html.split("<script>").find(s => s.includes('"use strict"'));
if (!inline) { console.error("インラインscriptが見つかりません"); process.exit(1); }
const code = inline.split("</script>")[0];

// ---- ブラウザAPIの最小スタブ（読み込み時のboot処理を通すため） ----
function fakeEl() {
  return {
    classList:{ add(){}, remove(){}, toggle(){}, contains(){return false;} },
    style:{}, dataset:{}, value:"", innerHTML:"", textContent:"", min:"", max:"", disabled:false,
    addEventListener(){}, removeEventListener(){}, appendChild(){}, removeChild(){},
    setPointerCapture(){}, removeAttribute(){}, setAttribute(){}, focus(){},
    getBoundingClientRect(){ return {left:0,top:0,width:0,height:0}; },
    querySelector(){ return fakeEl(); }, querySelectorAll(){ return []; }, closest(){ return null; },
  };
}
const chain = new Proxy(function(){}, { get(){ return chain; }, apply(){ return chain; } });
const context = {
  console,
  window:{ APP_CONFIG:{ SUPABASE_URL:"https://xtkphviiclzxszhlbwts.supabase.co", SUPABASE_ANON_KEY:"sb_publishable_test" } },
  document:{ getElementById(){ return fakeEl(); }, createElement(){ return fakeEl(); }, addEventListener(){}, querySelector(){ return fakeEl(); }, querySelectorAll(){ return []; }, body:fakeEl() },
  supabase:{ createClient(){ return {
    auth:{ onAuthStateChange(){}, getSession:async()=>({data:{session:null}}), signOut:async()=>{}, signUp:async()=>({error:null}), signInWithPassword:async()=>({error:null}) },
    from(){ return chain; }, channel(){ return { on(){ return this; }, subscribe(){} }; },
  }; } },
  confirm(){ return true; }, alert(){}, location:{ reload(){} }, setTimeout, clearTimeout,
};
vm.createContext(context);
vm.runInContext(code, context, { filename:"index.inline.js" });

// ---- アサーション ----
let pass=0, fail=0; const fails=[];
const j = v => JSON.stringify(v);
function eq(actual, expected, name){ const ok = j(actual)===j(expected); if(ok) pass++; else { fail++; fails.push(`${name}: 期待 ${j(expected)} / 実際 ${j(actual)}`); } }
function ok(cond, name){ if(cond) pass++; else { fail++; fails.push(name); } }
const t = context;
const pick = r => r ? { start:r.start, end:r.end } : r;
const LIM = { bookable_start_time:"10:00:00", bookable_end_time:"11:00:00" };   // 10-11制限
const UN  = { bookable_start_time:null, bookable_end_time:null };              // 制限なし
const D = (h,mi)=> new Date(2026,0,1,h,mi,0,0);

// 1) 時刻⇔分 変換
eq(t.hmToMin("10:00"), 600, "hmToMin(10:00)");
eq(t.hmToMin("13:30"), 810, "hmToMin(13:30)");
eq(t.hmToMin("00:00"), 0,   "hmToMin(00:00)");
eq(t.hmToMin("23:59"), 1439,"hmToMin(23:59)");
eq(t.hhmmShort("10:00:00"), "10:00", "hhmmShort");

// 2) グリッド範囲（START_H=7, END_H=24）
eq(t.totalMins(), 1020, "totalMins(=17h)");
eq(t.totalCells(), 68,  "totalCells(=68)");

// 3) minsFrom7
eq(t.minsFrom7(D(7,0)),   0,   "minsFrom7(7:00)");
eq(t.minsFrom7(D(10,30)), 210, "minsFrom7(10:30)");
eq(t.minsFrom7(D(23,0)),  960, "minsFrom7(23:00)");

// 4) cellOf（0..67にクランプ）
eq(t.cellOf(0),0,"cellOf(0)"); eq(t.cellOf(14),0,"cellOf(14)"); eq(t.cellOf(15),1,"cellOf(15)");
eq(t.cellOf(180),12,"cellOf(180=10:00)"); eq(t.cellOf(1020),67,"cellOf(1020 clamp)");
eq(t.cellOf(-10),0,"cellOf(負)"); eq(t.cellOf(99999),67,"cellOf(特大)");

// 5) toHM / toHMcap（全時間帯 & 23:59キャップ）
eq(t.toHM(0),"07:00","toHM(0)"); eq(t.toHM(180),"10:00","toHM(180)");
eq(t.toHM(960),"23:00","toHM(960)"); eq(t.toHM(1020),"24:00","toHM(1020)"); eq(t.toHM(1200),"24:00","toHM(clamp)");
eq(t.toHMcap(240),"11:00","toHMcap(240)"); eq(t.toHMcap(1019),"23:59","toHMcap(1019)"); eq(t.toHMcap(1020),"23:59","toHMcap(1020→23:59)");

// 6) 制限判定・制限枠
ok(!!t.isLimited(LIM), "isLimited(制限あり)");
ok(!t.isLimited(UN), "isLimited(制限なし)");
eq(t.winStartMins(LIM),180,"winStartMins(10-11)"); eq(t.winEndMins(LIM),240,"winEndMins(10-11)");

// 7) clampCells（制限帯の外は選択不可=null）
eq(t.clampCells(5,10,UN),[5,10],"clampCells(制限なし)");
eq(t.clampCells(-3,999,UN),[0,67],"clampCells(端クランプ)");
eq(t.clampCells(0,67,LIM),[12,15],"clampCells(制限帯へ収める)");
eq(t.clampCells(0,5,LIM),null,"clampCells(制限帯より前=null)");
eq(t.clampCells(20,30,LIM),null,"clampCells(制限帯より後=null)");
eq(t.clampCells(13,14,LIM),[13,14],"clampCells(制限帯内はそのまま)");

// 8) dragRange（選択15分枠を予約枠に内包 / クリック=30分 / 制限帯クランプ / 23:59キャップ）
eq(pick(t.dragRange(12,15,UN,true)), {start:"10:00",end:"11:00"}, "drag 4枠→10:00-11:00");
eq(pick(t.dragRange(12,12,UN,true)), {start:"10:00",end:"10:15"}, "drag 1枠→選択枠を内包(10:00-10:15)");
eq(pick(t.dragRange(12,12,UN,false)),{start:"10:00",end:"10:30"}, "クリックのみ→30分");
eq(pick(t.dragRange(15,12,UN,true)), {start:"10:00",end:"11:00"}, "逆方向ドラッグも同結果");
eq(pick(t.dragRange(67,67,UN,true)), {start:"23:45",end:"23:59"}, "最終枠→23:59でキャップ(右端はみ出し防止)");
eq(pick(t.dragRange(0,14,LIM,true)), {start:"10:00",end:"10:45"}, "制限外から開始→制限帯へクランプ");
eq(t.dragRange(30,40,LIM,true), null, "制限帯の完全外ドラッグ→不可");
eq(t.dragRange(20,20,LIM,false), null, "制限帯外クリック→不可");

// 9) HTMLエスケープ
eq(t.esc('<b>&"x"'), "&lt;b&gt;&amp;&quot;x&quot;", "esc");

// ---- 静的ガード：狭幅レイアウト崩れバグの再発防止 ----
ok(/class="hcell" style="width:\$\{PX_H\}px"/.test(html), "[静的] ヘッダ時間セル幅=PX_H(本体グリッドと同期)");
ok(!/max-width:600px[^}]*--px-per-hour/.test(html), "[静的] 狭幅で --px-per-hour を上書きしない(ズレ防止)");
ok(/#appView\{display:flex;flex-direction:column;height:100vh\}/.test(html), "[静的] #appView は全高フレックス縦");
ok(/\.gridscroll\{flex:1;min-height:0;overflow:auto\}/.test(html), "[静的] グリッドは残余領域を埋める");
ok(!/gridscroll\{overflow:auto;height:calc/.test(html), "[静的] gridscroll は固定calc高さを使わない");
ok(/\.disband\{/.test(html), "[静的] 制限帯の非活性バンド定義あり");
ok(/weekDown/.test(html), "[静的] 週ビューのドラッグ有効");
ok(/\.track\{position:relative;flex:none;/.test(html), "[静的] トラックは flex:none で縮まない(狭幅崩れ防止)");
ok(/\.room-row\{display:flex;width:max-content;/.test(html), "[静的] 行は内容幅でヘッダと横スクロール整合");
ok(/\.timehead\{display:flex;width:max-content;/.test(html), "[静的] ヘッダも内容幅で本体と整合");

// ---- 10) 時刻コンボの30分候補（制限帯はその範囲のみ） ----
const marksUN = t.buildTimeMarks(UN);
eq(marksUN[0], "07:00", "buildTimeMarks 先頭=07:00");
eq(marksUN[marksUN.length-1], "23:30", "buildTimeMarks 末尾=23:30(24:00は出さない)");
eq(marksUN.length, 34, "buildTimeMarks 個数=34(07:00〜23:30/30分刻み)");
eq(t.buildTimeMarks(LIM), ["10:00","10:30","11:00"], "buildTimeMarks 制限10-11");
eq(t.buildTimeMarks({bookable_start_time:"13:00:00",bookable_end_time:"14:00:00"}), ["13:00","13:30","14:00"], "buildTimeMarks 制限13-14");

// ---- 11) 時刻の正規化（自由入力→HH:MM） ----
eq(t.normalizeTime("14"),   "14:00", "normalizeTime 14→14:00");
eq(t.normalizeTime("1430"), "14:30", "normalizeTime 1430→14:30");
eq(t.normalizeTime("930"),  "09:30", "normalizeTime 930→09:30");
eq(t.normalizeTime("9:5"),  "09:05", "normalizeTime 9:5→09:05");
eq(t.normalizeTime("25:00"),"23:00", "normalizeTime 25:00→23:00(時をクランプ)");
eq(t.normalizeTime("10:75"),"10:59", "normalizeTime 10:75→10:59(分をクランプ)");
eq(t.normalizeTime("abc"),  "abc",   "normalizeTime 不正→そのまま(検証は別)");

// ---- 12) HH:MM 妥当性 ----
ok(t.validHM("10:00"),  "validHM 10:00");
ok(t.validHM("23:59"),  "validHM 23:59");
ok(t.validHM("9:05"),   "validHM 9:05");
ok(!t.validHM("24:00"), "validHM 24:00は不可");
ok(!t.validHM("10:60"), "validHM 10:60は不可");
ok(!t.validHM("abc"),   "validHM abcは不可");

// ---- 13) 参加者リアルタイム検索（部分一致＋除外） ----
// ---- 13) 参加者：登録ユーザー検索(オブジェクト)＋自由入力の区別 ----
const PPL=[{id:"u1",name:"Tanaka"},{id:"u2",name:"Sato"},{id:"u3",name:"Takahashi"}];
eq(t.filterPeople(PPL,"ta",[]).map(p=>p.name), ["Tanaka","Takahashi"], "filterPeople 部分一致(大小無視)");
eq(t.filterPeople(PPL,"",["Sato"]).map(p=>p.name), ["Tanaka","Takahashi"], "filterPeople 追加済み(名前)を除外");
eq(t.filterPeople([{id:"a",name:"田中"},{id:"b",name:"佐藤"}],"田",[]).map(p=>p.id), ["a"], "filterPeople 日本語部分一致(id保持)");
eq(t.filterPeople([],"x",[]), [], "filterPeople 空");
eq(t.chipOpenIds([{name:"Tanaka",uid:"ou_1"},{name:"自由太郎",uid:null},{name:"Sato",uid:"ou_2"}]), ["ou_1","ou_2"], "chipOpenIds 候補選択のopen_idのみ");
eq(t.chipOpenIds([{name:"A",uid:"ou_1"},{name:"B",uid:"ou_1"}]), ["ou_1"], "chipOpenIds 重複除去");
eq(t.chipOpenIds([{name:"自由",uid:null}]), [], "chipOpenIds 自由入力のみ→空");
eq(t.chipsFromBooking(["Tanaka","ゲスト花子"], PPL), [{name:"Tanaka",uid:"u1"},{name:"ゲスト花子",uid:null}], "chipsFromBooking 候補はuid/未登録はnull");
ok(/participant_open_ids:chipOpenIds\(S\.chips\)/.test(html), "[静的] 保存payloadに参加者open_ids");
ok(/data-uid="\$\{p\.id\}"/.test(html), "[静的] 参加者候補にdata-uid付与");
ok(/\/participant_open_ids\/\.test\(res\.error\.message/.test(html), "[静的] 13未適用時はparticipant_open_idsを外して再試行");
ok(/sb\.rpc\("list_directory"\)/.test(html), "[静的] 参加者候補は全社ディレクトリ(list_directory)から");
ok(/async function loadDirectory\(\)/.test(html), "[静的] loadDirectory 実装あり");
ok(/全社から検索/.test(html), "[静的] 参加者入力プレースホルダが全社検索");

// ---- 静的ガード：モーダルの新仕様 ----
ok(!/<datalist/.test(html), "[静的] 旧datalistは撤去済み");
ok(/id="bkNotify"/.test(html) && /通知しない/.test(html), "[静的] 通知(Lark)セレクトあり");
ok(/id="bkStartList"/.test(html) && /id="bkEndList"/.test(html), "[静的] 開始/終了の時刻コンボ候補リストあり");
ok(/id="bkPartList"/.test(html), "[静的] 参加者の検索候補リストあり");
ok(/\.tcombo\{position:relative\}/.test(html), "[静的] コンボのCSSあり");
ok(/id="bkOrganizer"/.test(html), "[静的] 予約者(ログイン者名の自動表示)欄あり");
ok(/notify_before_min:\s*nb\?\s*parseInt/.test(html), "[静的] 保存payloadに通知分を含む");
ok(/setupTimeCombo\("bkStart"/.test(html) && /setupPartCombo\(\)/.test(html), "[静的] コンボ初期化を呼んでいる");

// ---- 静的ガード：時刻コンボの配線（30分ドロップダウンが出るための必須条件） ----
ok(/id="bkStart" type="text"/.test(html) && /id="bkEnd" type="text"/.test(html), "[静的] 開始/終了はテキスト入力(コンボ)");
ok(!/id="bkStart" type="time"/.test(html) && !/id="bkEnd" type="time"/.test(html), "[静的] 旧 type=time は残っていない");
ok(/inp\.addEventListener\("focus", openList\)/.test(html), "[静的] コンボは focus で開く");
ok(/inp\.addEventListener\("click", openList\)/.test(html), "[静的] コンボは click(タップ)で開く");
ok(/list\.classList\.add\("show"\)/.test(html), "[静的] コンボ表示クラス(show)を付与");
ok(/list\.addEventListener\("pointerdown"/.test(html), "[静的] 候補タップで選択(pointerdown)");
ok(/renderTimeOpts\(inp,list\)/.test(html), "[静的] 候補は buildTimeMarks 経由(renderTimeOpts)で描画");
ok(["5","10","15","30","60"].every(v=>new RegExp('<option value="'+v+'"').test(html)), "[静的] 通知の選択肢 5/10/15/30/60 が揃う");
ok(/bkOrganizer"\)\.textContent = S\.profile\.display_name/.test(html), "[静的] 新規時は予約者にログイン者名を自動表示");
ok(/notify_sent_at:null/.test(html), "[静的] 保存payloadで通知を再アーム(notify_sent_at:null)");
ok(/const BUILD *= *"/.test(html), "[静的] ビルド版マーカーあり(デプロイ確認用)");
ok(/個人DMで送信/.test(html) && !/Lark グループに送信されます/.test(html), "[静的] 通知ヒントは個人DM文言(旧グループ文言に戻っていない)");

// ---- 14) 配置図（レイアウト）純関数 ----
const R = [
  {id:"a",no:5, area:"L-Spot", row:1, col:2},
  {id:"b",no:9, area:"L-Spot", row:2, col:1},
  {id:"c",no:4, area:"L-Spot", row:2, col:2},
  {id:"d",no:10,area:"マリージョア", row:1, col:1},
  {id:"e",no:12,area:"マリージョア", row:1, col:3},
  {id:"f",no:99,area:"未設定", row:null, col:null},
];
eq(t.layGridSize(R,"L-Spot",1,1), {rows:2,cols:2}, "layGridSize L-Spot=2x2");
eq(t.layGridSize(R,"マリージョア",1,1), {rows:1,cols:3}, "layGridSize マリージョア=1x3");
eq(t.layGridSize(R,"空エリア",1,1), {rows:1,cols:1}, "layGridSize 空=最小1x1");
eq(t.layAt(R,"L-Spot",2,1) ? t.layAt(R,"L-Spot",2,1).id : null, "b", "layAt (2,1)=b");
eq(t.layAt(R,"L-Spot",1,1), null, "layAt 空マス=null");
eq(t.layAreas(R), ["L-Spot","マリージョア","未設定"], "layAreas 出現順");
// 空マスへ移動（入替なし・純粋=元配列不変）
const m1=t.layMove(R,"a","L-Spot",3,1);
eq(m1.find(x=>x.id==="a"), {id:"a",no:5,area:"L-Spot",row:3,col:1}, "layMove 空マスへ移動");
eq(R[0].row, 1, "layMove 元配列は不変(純粋)");
// 占有マスへ移動＝入替
const m2=t.layMove(R,"a","L-Spot",2,1);
eq([m2.find(x=>x.id==="a").row, m2.find(x=>x.id==="a").col], [2,1], "layMove 入替: a→(2,1)");
eq([m2.find(x=>x.id==="b").row, m2.find(x=>x.id==="b").col], [1,2], "layMove 入替: b→aの旧位置(1,2)");
// エリアをまたぐ配置（未配置→配置）
const m3=t.layMove(R,"f","マリージョア",2,2);
eq(m3.find(x=>x.id==="f"), {id:"f",no:99,area:"マリージョア",row:2,col:2}, "layMove 未配置→別エリアへ配置");

// ---- 静的ガード：配置図/編集 ----
ok(/\.lay-grid\{position:relative;display:grid/.test(html), "[静的] 配置図グリッドCSSあり");
ok(/\.lay-table/.test(html) && /マリージョア/.test(html), "[静的] マリージョアにテーブル描画");
ok(/const admin = S\.profile && S\.profile\.is_admin/.test(html), "[静的] 編集は管理者のみ");
ok(/layout_row:b\.row, layout_col:b\.col/.test(html), "[静的] 保存で座標を更新");
ok(/data-grow/.test(html) && /data-cell/.test(html) && /data-booth/.test(html), "[静的] 委譲クリック用の data 属性あり");
ok(/openBooking\(null,\{room:id,date:ymd\(S\.date\)/.test(html), "[静的] 閲覧時ブースタップで予約を開く");
ok(/10:00〜11:00のみ/.test(html) && !/10-11のみ/.test(html), "[静的] 制限時間表記が10:00〜11:00のみ");

// ---- 静的ガード：会議ブースの削除（論理削除 / 管理者のみ / 編集モード） ----
ok(/async function layDeleteBooth\(id\)/.test(html), "[静的] ブース削除関数あり");
ok(/sb\.rpc\("set_room_active", ?\{ ?p_id:id, ?p_active:false ?\}\)/.test(html), "[静的] set_room_activeで論理削除(is_active=false)");
ok(/\(admin&&S\.layEditing\)\?`<button class="lay-del" data-del="\$\{b\.id\}"/.test(html), "[静的] 編集モードのみ削除ボタン(×)を表示");
ok(/e\.target\.closest\("\[data-del\]"\)/.test(html), "[静的] 削除ボタンのクリック委譲");
ok(/\.lay-del\{position:absolute/.test(html), "[静的] 削除ボタンのスタイル(.lay-del)");
ok(/gte\("ends_at", ?new Date\(\)\.toISOString\(\)\)/.test(html) && /今後の予約が/.test(html), "[静的] 削除前に今後の予約件数を警告");
{
  const mig = path.join(HERE, "25_room_soft_delete.sql");
  const sql = fs.existsSync(mig) ? fs.readFileSync(mig, "utf8") : "";
  ok(/function public\.set_room_active\(p_id uuid, ?p_active boolean\)/.test(sql), "[静的] migration25: set_room_active RPC");
  ok(/if not public\.is_admin\(\) then raise exception 'forbidden'/.test(sql), "[静的] migration25: 管理者のみ許可");
}
ok(/class="lay-door"/.test(html) && />入口</.test(html) && />扉</.test(html), "[静的] 扉/入口マーカー描画");
ok(/bottom:-11px/.test(html) && /left:-11px/.test(html), "[静的] 入口(下辺)と扉(左辺)を配置");
ok(/await loadRooms\(\); buildWeekRoomSelect\(\); await reload\(\); openPlace\(\)/.test(html), "[静的] 保存後にrooms再取得(反映バグ修正)");
ok(/const notSaved=results\.filter/.test(html), "[静的] 保存で0行更新(権限)を検知");

// ---- 繰り返し予約（Lark相当） ----
const fmtOcc = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")} ${String(d.getHours()).padStart(2,"0")}:${String(d.getMinutes()).padStart(2,"0")}`;
{
  let occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,11,0), {freq:"none"});
  eq(occ.length, 1, "expand none→1件");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,11,0), {freq:"daily",endType:"count",count:3});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-05 10:00","2026-01-06 10:00","2026-01-07 10:00"], "毎日×3");
  eq(occ[0].end.getHours(), 11, "duration保持(終了11時)");
  occ=t.expandRecurrence(new Date(2026,0,9,9,0), new Date(2026,0,9,9,30), {freq:"weekday",endType:"count",count:3});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-09 09:00","2026-01-12 09:00","2026-01-13 09:00"], "平日×3(週末スキップ)");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,10,30), {freq:"weekly",endType:"count",count:3});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-05 10:00","2026-01-12 10:00","2026-01-19 10:00"], "毎週×3");
  occ=t.expandRecurrence(new Date(2026,0,31,10,0), new Date(2026,0,31,10,30), {freq:"monthly",endType:"count",count:3});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-31 10:00","2026-03-31 10:00","2026-05-31 10:00"], "毎月31日(無い月スキップ)");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,10,30), {freq:"custom",unit:"week",interval:2,weekdays:[1,3],endType:"count",count:4});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-05 10:00","2026-01-07 10:00","2026-01-19 10:00","2026-01-21 10:00"], "カスタム隔週(月・水)×4");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,11,0), {freq:"daily",endType:"until",until:"2026-01-07"});
  eq(occ.length, 3, "毎日 終了日指定(5,6,7)");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,11,0), {freq:"daily",endType:"count",count:100}, 100);
  eq(occ.length, 100, "上限100でキャップ");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,11,0), {freq:"daily",endType:"count",count:150}, 101);
  eq(occ.length, 101, "101件まで展開(上限超過の検知用)");
  occ=t.expandRecurrence(new Date(2026,0,5,10,0), new Date(2026,0,5,10,30), {freq:"custom",unit:"month",interval:2,endType:"count",count:3});
  eq(occ.map(o=>fmtOcc(o.start)), ["2026-01-05 10:00","2026-03-05 10:00","2026-05-05 10:00"], "カスタム2ヶ月ごと×3");
}
eq(t.repeatRuleLabel({freq:"weekly"}), "毎週", "ラベル 毎週");
eq(t.repeatRuleLabel({freq:"custom",unit:"week",interval:2,weekdays:[1,3]}), "2週ごと（月・水）", "ラベル カスタム隔週");
eq(t.repeatRuleLabel({freq:"none"}), null, "ラベル none→null");
ok(/id="bkRepeat"/.test(html), "[静的] 繰り返しセレクトあり");
ok(/繰り返さない/.test(html)&&/毎日/.test(html)&&/毎週/.test(html)&&/毎月/.test(html)&&/平日（月〜金）/.test(html)&&/カスタム/.test(html), "[静的] Lark相当の繰り返し選択肢");
ok(/function expandRecurrence/.test(html), "[静的] expandRecurrence 実装あり");
ok(/recurrence_group:group/.test(html), "[静的] 保存でrecurrence_groupを付与");
ok(/eq\("recurrence_group",g\)\.gte\("starts_at"/.test(html), "[静的] シリーズ取消(この回以降)対応");
ok(/最大100回/.test(html), "[静的] 100回上限の注記");
ok(/繰り返しは最大100回までです。回数または終了日/.test(html), "[静的] 上限超過バリデーション");
ok(/繰り返しの終了日を指定してください/.test(html), "[静的] 終了日未指定バリデーション");
ok(/id="bkRepUntil"[^>]*type="date"[^>]*showPicker/.test(html), "[静的] 終了日はカレンダー(showPicker)");
ok(/id="bkDate"[^>]*type="date"[^>]*showPicker/.test(html), "[静的] 日付はカレンダー(showPicker)");
ok(/max="100"/.test(html), "[静的] 回数入力max=100");

// ---- 過去日時の予約を許可（旧ブロックを撤去） ----
ok(!/function nowClampMin/.test(html), "[静的] 現在時刻クランプ(nowClampMin)を撤去");
ok(!/minMin/.test(html), "[静的] minMin参照が残っていない(過去クランプ撤去)");
ok(!/ymd\(new Date\(\)\)\) return/.test(html), "[静的] 過去日ドラッグのブロックを撤去");
eq(pick(t.dragRange(32,32,UN,true)), {start:"15:00",end:"15:15"}, "過去含む時間帯もクランプなしで選択可(15:00)");
eq(pick(t.dragRange(20,40,UN,true)), {start:"12:00",end:"17:15"}, "過去にまたがる範囲もそのまま選択可");
ok(/class="pastband"/.test(html), "[静的] 過去帯の視覚表示は維持");

// ---- 繰り返し予約の編集 ----
eq(t.ruleFromBooking({recurrence_rule_json:{freq:"custom",unit:"week",interval:2,weekdays:[1,3],endType:"count",count:8}}).interval, 2, "編集: JSONから復元");
eq(t.ruleFromBooking({recurrence_rule:"毎週"}).freq, "weekly", "編集: ラベル毎週→復元");
eq(t.ruleFromBooking({recurrence_rule:"平日（月〜金）"}).freq, "weekday", "編集: ラベル平日→復元");
eq(t.ruleFromBooking({recurrence_rule:"毎月"}).freq, "monthly", "編集: ラベル毎月→復元");
ok(/function applyRuleToUI/.test(html), "[静的] 繰り返し編集(applyRuleToUI)");
ok(/この予定以降すべてに反映/.test(html), "[静的] シリーズ編集(この予定以降すべて)");
ok(/recurrence_rule_json:\(group\?rule:null\)/.test(html), "[静的] 新規で繰り返しルールをJSON保存");
ok(/if\(\/recurrence_rule_json\/\.test\(m\)/.test(html), "[静的] 15未適用時のフォールバック");

// ---- 過去予約は登録のみ / 編集・削除は管理者のみ / 進行中は現在時刻で終了 ----
ok(/過去の予約は削除できません（管理者のみ）/.test(html), "[静的] 過去予約は本人でも削除不可(管理者のみ)");
ok(/過去の予約は編集できません（管理者のみ）/.test(html), "[静的] 過去予約は本人でも編集不可(管理者のみ)");
ok(/e<=now && !S\.profile\.is_admin/.test(html), "[静的] 削除ガード: 過去は管理者のみ通過");
ok(/進行中の予約です。現在時刻で終了/.test(html), "[静的] 進行中は現在時刻で終了(確認)");
ok(/ends_at:endNow\.toISOString\(\)/.test(html), "[静的] 進行中は終了時刻を現在に更新");
ok(/const ended = new Date\(b\.ends_at\) <= new Date\(\)/.test(html), "[静的] 終了済み判定(ended)で権限分岐");
ok(/min-height:var\(--row-h\);align-self:stretch/.test(html), "[静的] トラックが行高さに追随(現在時刻線の見切れ防止)");

// ---- ドラッグ選択: 過去クランプを撤去（過去でもそのまま選択可） ----
{ const R={};
  eq(pick(t.dragRange(32,32,R,true)), {start:"15:00",end:"15:15"}, "過去でもクランプなし(15:00)");
  eq(t.dragRange(20,24,R,true).start, "12:00", "以前は不可だった範囲も選択可(12:00)");
  eq(t.dragRange(48,52,R,true).start, "19:00", "未来はそのまま(19:00)");
}
ok(!/startMin<minMin/.test(html), "[静的] 開始の現在時刻クランプを撤去");

// ---- 管理者権限の付与UI ----
ok(/sb\.rpc\("list_users_admin"\)/.test(html), "[静的] 管理者: ユーザー一覧RPC");
ok(/sb\.rpc\("set_admin"/.test(html), "[静的] 管理者: 権限付与RPC");
ok(/function toggleAdmin/.test(html)&&/function renderAdminList/.test(html), "[静的] 管理者: UI関数あり");
ok(/id="adminList"/.test(html), "[静的] 管理者: 一覧コンテナ");

// ---- パスワード再設定(Lark BOT) ----
ok(/function forgotPassword/.test(html), "[静的] パスワード再設定: 送信関数");
ok(/functions\/v1\/password-reset-lark/.test(html), "[静的] パスワード再設定: Edge Function呼び出し");
ok(/evt==="PASSWORD_RECOVERY"/.test(html), "[静的] パスワード再設定: recoveryイベント処理");
ok(/function submitRecovery/.test(html)&&/sb\.auth\.updateUser\(\{ password/.test(html), "[静的] パスワード再設定: 新パスワード更新");
ok(/id="pwView"/.test(html), "[静的] パスワード再設定: 入力モーダル");

// ---- UI改善（画面外クリック / 通知デフォルト / IME / 候補位置）----
ok(/ov===_ovDown && ov\.classList\.contains\("overlay"\)/.test(html), "[静的] 画面外クリックで閉じる");
ok(/<option value="5" selected>/.test(html), "[静的] 通知デフォルトは5分前(option)");
ok(/\$\("bkNotify"\)\.value="5"/.test(html), "[静的] 新規予約の通知デフォルト5分前");
ok(/\(e\.key==="Enter"\|\|e\.key===","\) && !e\.isComposing/.test(html), "[静的] IME確定Enterで入力値を追加しない");
ok(/id="bkPartList" class="tcombo-list up"/.test(html), "[静的] 参加者候補は入力欄の上に表示");
ok(/\.tcombo-list\.up\{top:auto;bottom:100%/.test(html), "[静的] 候補リスト上向きスタイル");
ok(/\.tcombo-list\.up\{[^}]*max-height:min\(70vh,520px\)/.test(html), "[静的] 参加者候補を画面上部まで拡大");
ok(/const canEdit = ended \? admin : own;/.test(html), "[静的] 過去(終了済み)は管理者のみ編集可");
ok(!/終了時刻が現在時刻より前の予約はできません/.test(html), "[静的] 過去の予約作成は可(登録のみ)");

// ---- 静的ガード：部門(Division)ベースの通知振り分け ----
ok(/id="stDivision"/.test(html), "[静的] 設定に所属部門セレクトあり");
ok(/id="nmDivision"/.test(html), "[静的] 登録(初回)に所属部門セレクトあり");
ok(/sb\.rpc\("list_divisions"\)/.test(html), "[静的] 部門一覧をRPCで取得");
ok(/fillDivisions\("nmDivision"/.test(html), "[静的] 登録時に部門欄を初期化");
ok(/if\(S\.divisionsFeature\) upd\.division = divSel\.value/.test(html), "[静的] 保存で部門も更新(機能有効時)");
ok(/所属部門を選択してください/.test(html) && /!fromSettings && S\.divisionsFeature/.test(html), "[静的] 登録時は所属部門が必須(設定は任意)");
ok(/select\("id,display_name,is_admin,division"\)/.test(html), "[静的] プロフィール取得に部門を含む");
ok(/if\(res\.error\)\{ res = await sb\.from\("profiles"\)\.select\("id,display_name,is_admin"\)/.test(html), "[静的] loadProfile: 取得エラー時に最小列で再取得(division列欠如でも名前入力ループしない)");

// ---- 静的ガード：Lark会議リンク（予約作成時に発行→アプリ表示＋通知） ----
ok(/function createMeetingLink\(occ, ?topic\)/.test(html), "[静的] 会議リンク発行ヘルパーあり");
ok(/functions\/v1\/create-lark-meeting/.test(html), "[静的] create-lark-meeting を呼ぶ");
ok(/end_time: ?Math\.floor\(last\.end\.getTime\(\)\/1000\)/.test(html), "[静的] 会議URL有効期限=予約終了(unix)");
ok(/chipOpenIds\(S\.chips\)\.length>0 ?\? ?await createMeetingLink/.test(html), "[静的] 参加者が1人以上のときのみ会議リンク発行");
{ const m = html.match(/meeting_url:meetingUrl/g) || []; ok(m.length >= 2, "[静的] 新規・シリーズ再作成の両方でmeeting_urlを保存"); }
ok(/if\(\/meeting_url\/\.test\(m\) && \("meeting_url" in payload\)\)\{ delete payload\.meeting_url/.test(html), "[静的] meeting_url列が無い環境でもフォールバック挿入");
ok(/function renderMeeting\(url\)/.test(html) && /id="bkMeeting"/.test(html), "[静的] 会議リンク表示(renderMeeting + #bkMeeting)");
ok(/\.mtg\{[^}]*border/.test(html), "[静的] 会議リンク表示スタイル(.mtg)");
ok(/renderMeeting\(b\.meeting_url\)/.test(html), "[静的] 既存予約を開くと会議リンクを表示");
ok(/renderMeeting\(null\)/.test(html), "[静的] 新規予約フォームでは会議リンク非表示");

// Edge Function / SQL 側の連動（ファイルを直接検査）
{
  const dmp = path.join(HERE, "supabase/functions/notify-lark-dm/index.ts");
  const dm = fs.existsSync(dmp) ? fs.readFileSync(dmp, "utf8") : "";
  ok(/b\.meeting_url \? `\\n会議リンク: \$\{b\.meeting_url\}`/.test(dm), "[静的] 通知DMに会議リンクを追記");
  const cmp = path.join(HERE, "supabase/functions/create-lark-meeting/index.ts");
  const cm = fs.existsSync(cmp) ? fs.readFileSync(cmp, "utf8") : "";
  ok(/vc\/v1\/reserves\/apply/.test(cm) && /vc\/v1\/reserve\/apply/.test(cm) && /user_id_type=open_id/.test(cm), "[静的] create-lark-meeting: VC予約API(reserves/reserve両対応)を呼ぶ");
  ok(/resolve_lark_open_id/.test(cm) && /owner_id: ?ownerId/.test(cm), "[静的] create-lark-meeting: 主催者open_idをownerに設定");
  const mig = path.join(HERE, "20_meeting_link.sql");
  const sql = fs.existsSync(mig) ? fs.readFileSync(mig, "utf8") : "";
  ok(/add column if not exists meeting_url text/.test(sql), "[静的] migration20: meeting_url列を追加");
  ok(/drop function if exists public\.due_meeting_dm\(\)/.test(sql) && /b\.meeting_url,/.test(sql), "[静的] migration20: due_meeting_dmがmeeting_urlを返す");
}

// ---- 静的ガード：パスワード表示/非表示トグル ----
ok(/function togglePw\(btn\)/.test(html), "[静的] パスワード表示切替関数あり");
ok(/inp\.type=show\?"text":"password"/.test(html), "[静的] type を password↔text で切替");
ok(/\.pw-toggle\{position:absolute/.test(html), "[静的] トグルボタンを入力欄右端に配置(.pw-toggle)");
ok(/\.pw-wrap input\{padding-right:44px\}/.test(html), "[静的] アイコン分の余白(padding-right)");
ok(/const EYE=/.test(html) && /const EYEOFF=/.test(html), "[静的] 目アイコン(EYE/EYEOFF)を定義");
{ const m = html.match(/class="pw-toggle" onclick="togglePw\(this\)"/g) || []; ok(m.length >= 3, "[静的] 3つのパスワード欄すべてにトグル(ログイン+再設定2)"); }
ok(/for\(const b of document\.querySelectorAll\("\.pw-toggle"\)\) b\.innerHTML=EYE/.test(html), "[静的] 起動時にトグルアイコンを初期化");

// ---- 静的ガード：氏名で open_id 連携（予約者本人へ通知）＋ウェルカムDM ----
ok(/async function linkLarkOpenId\(\)/.test(html) && /sb\.rpc\("link_open_id_by_name"\)/.test(html), "[静的] 氏名で open_id 連携するヘルパー");
ok(/async function sendWelcomeDM\(\)/.test(html) && /functions\/v1\/welcome-lark/.test(html), "[静的] ウェルカムDM送信ヘルパー");
ok(/const oid=await linkLarkOpenId\(\); ?if\(oid\) ?sendWelcomeDM\(\); ?route\(\);/.test(html), "[静的] 初回登録で 連携→ウェルカムDM→遷移");
ok(/hide\("nameView"\); show\("appView"\);\s*linkLarkOpenId\(\);/.test(html), "[静的] ログイン毎に未連携を氏名で再連携");
{
  const mig = path.join(HERE, "21_link_open_id_by_name.sql");
  const sql = fs.existsSync(mig) ? fs.readFileSync(mig, "utf8") : "";
  ok(/add column if not exists lark_welcomed_at/.test(sql), "[静的] migration21: lark_welcomed_at 列");
  ok(/function public\.link_open_id_by_name\(\)/.test(sql) && /norm_name/.test(sql), "[静的] migration21: 氏名連携RPC(link_open_id_by_name)");
  ok(/function public\.relink_open_ids_by_name\(\)/.test(sql), "[静的] migration21: 一括連携RPC(relink_open_ids_by_name)");
  ok(/select public\.relink_open_ids_by_name\(\)/.test(sql), "[静的] migration21: 既存者バックフィルを実行");
  const wp = path.join(HERE, "supabase/functions/welcome-lark/index.ts");
  const w = fs.existsSync(wp) ? fs.readFileSync(wp, "utf8") : "";
  ok(/receive_id_type=open_id/.test(w) && /resolve_lark_open_id/.test(w), "[静的] welcome-lark: open_id宛にDM送信");
  ok(/body\?\.all === true/.test(w) && /x-cron-secret/.test(w), "[静的] welcome-lark: 既存者一括(all)はCRON_SECRET保護");
  ok(/lark_welcomed_at/.test(w), "[静的] welcome-lark: 重複送信防止(welcomed_at)");
  const sp = path.join(HERE, "supabase/functions/sync-lark-users/index.ts");
  const s = fs.existsSync(sp) ? fs.readFileSync(sp, "utf8") : "";
  ok(/rpc\/relink_open_ids_by_name/.test(s), "[静的] 同期でも氏名一括連携を実行");
}

// ---- 静的ガード：管理者は他人の予約を削除できる ----
ok(/const canDelete = admin \|\| \(own && !ended\);/.test(html), "[静的] 過去は管理者のみ削除可(未来は本人/管理者)");
{
  const mig = path.join(HERE, "22_admin_booking_manage.sql");
  const sql = fs.existsSync(mig) ? fs.readFileSync(mig, "utf8") : "";
  ok(/policy bookings_delete_admin on public\.bookings\s*\n?\s*for delete to authenticated using \(public\.is_admin\(\)\)/.test(sql), "[静的] migration22: 管理者DELETEポリシー");
  ok(/policy bookings_update_admin on public\.bookings/.test(sql) && /for update to authenticated using \(public\.is_admin\(\)\)/.test(sql), "[静的] migration22: 管理者UPDATEポリシー(進行中の取消用)");
}

// ---- 静的ガード：メンバー（許可リスト）の画面管理（管理者のみ） ----
ok(/id="memberList"/.test(html) && /id="memAddName"/.test(html), "[静的] システム設定にメンバー管理欄");
ok(/async function renderMemberList\(\)/.test(html) && /sb\.rpc\("list_members_admin"\)/.test(html), "[静的] メンバー一覧(list_members_admin)");
ok(/sb\.rpc\("add_member_admin", ?\{ ?p_name:name ?\}\)/.test(html), "[静的] メンバー追加(add_member_admin)");
ok(/sb\.rpc\("remove_member_admin", ?\{ ?p_name:name ?\}\)/.test(html), "[静的] メンバー削除(remove_member_admin)");
ok(/sb\.rpc\("admin_resync_members"\)/.test(html) && /sb\.rpc\("admin_relink_members"\)/.test(html), "[静的] 再同期・再連携RPC");
ok(/renderAdminList\(\); renderMemberList\(\);/.test(html), "[静的] システム設定を開くとメンバー一覧を描画");
ok(/S\.people = await loadDirectory\(\)/.test(html), "[静的] 追加/削除後に参加者候補を再読込");
ok(/addMember\(\)"/.test(html) && /!event\.isComposing\)addMember\(\)/.test(html), "[静的] Enterで追加(IME変換中は除外)");
ok(/function openSys\(\)\{ if\(!S\.profile\.is_admin\) return;/.test(html), "[静的] メンバー管理は管理者のみ(openSysガード)");
{
  const mig = path.join(HERE, "26_member_management.sql");
  const sql = fs.existsSync(mig) ? fs.readFileSync(mig, "utf8") : "";
  const fns = ["list_members_admin","add_member_admin","remove_member_admin","admin_resync_members","admin_relink_members"];
  ok(fns.every(f=>new RegExp("function public\\."+f+"\\(").test(sql)), "[静的] migration26: 5つのRPCを定義");
  ok((sql.match(/if not public\.is_admin\(\) then raise exception 'forbidden'/g)||[]).length===4 && /where public\.is_admin\(\)/.test(sql), "[静的] migration26: 全RPCが管理者限定");
  ok(/raise exception 'last'/.test(sql), "[静的] migration26: 最後の1人は削除不可(全員取込の防止)");
  ok(/perform public\.trigger_lark_sync\(\)/.test(sql), "[静的] migration26: 追加時にLark同期を起動");
}

// ---- 静的ガード：BUILDマーカー ----
ok(/const BUILD = "2026-07-15-15"/.test(html), "[静的] BUILDマーカー更新(11)");

// ---- 結果 ----
console.log(`\n=== フロントエンド単体テスト結果 ===`);
if(fail===0){ console.log(`✅ 全 ${pass} 項目 PASS`); }
else { console.log(`❌ ${fail} 件 失敗 / ${pass} 件成功`); fails.forEach(f=>console.log("  - "+f)); process.exit(1); }
