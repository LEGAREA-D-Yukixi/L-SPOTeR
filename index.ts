// supabase/functions/create-lark-meeting/index.ts
// 予約作成時にフロントから呼ばれ、Lark ビデオ会議(VC)を予約して参加URLを返す。
// 参加者が1人以上いる予約のときだけフロントが呼ぶ。verify_jwt=false + CORS。
//
// 入力(JSON): { email: 主催者メール, topic: 会議名, end_time: 終了unix秒(number|string),
//              participant_open_ids?: 参加者の open_id 配列（主催者が未連携のときのホスト候補） }
// 出力(JSON): { url: string|null, reason?, ... }   ※失敗時は reason を返す(原因切り分け用)
//
// 必要な Secrets: LARK_APP_ID, LARK_APP_SECRET（SUPABASE_URL/SERVICE_ROLE_KEY は自動注入）
// 必要な Lark 権限(公開済み): vc:reserve（会議の予約）＋ VC(ビデオ会議)が有効なテナント
//
// 直接テスト:
//   curl -sS -X POST "<FUNCTION_URL>" -H "content-type: application/json" \
//     -d '{"email":"you@example.com","topic":"テスト","end_time":<未来のunix秒>}'
//   → {"url":"https://..."} なら成功。{"url":null,"reason":...} なら理由を確認。

const LARK = "https://open.larksuite.com/open-apis";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// VC予約を1エンドポイントに対して試す
async function tryReserve(path: string, token: string, endTime: number, ownerId: string, topic: string) {
  const r = await fetch(`${LARK}${path}?user_id_type=open_id`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ end_time: String(Math.floor(endTime)), owner_id: ownerId, meeting_settings: { topic } }),
  });
  const j: any = await r.json().catch(() => null);
  const url = j?.data?.reserve?.url ?? j?.data?.reserve?.meeting_url ?? null;
  return { status: r.status, code: j?.code, msg: j?.msg, url, raw: j };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const body = await req.json().catch(() => ({} as any));
    const email = String(body?.email ?? "").trim();
    const topic = String(body?.topic ?? "会議").slice(0, 100) || "会議";
    const endTime = Number(body?.end_time ?? 0);
    const parts: string[] = Array.isArray(body?.participant_open_ids)
      ? body.participant_open_ids.map((x: unknown) => String(x)).filter((x: string) => /^ou_/.test(x)) : [];
    if (!email || !endTime) return json({ url: null, reason: "bad-input", email, endTime });

    const SB_URL = Deno.env.get("SUPABASE_URL")!;
    const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const APP_ID = Deno.env.get("LARK_APP_ID") ?? "";
    const APP_SECRET = Deno.env.get("LARK_APP_SECRET") ?? "";
    if (!APP_ID || !APP_SECRET) return json({ url: null, reason: "no-lark-secret" });
    const sbHeaders = { "Content-Type": "application/json", apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` };

    // 1) 主催者の open_id を解決（profiles → lark_directory）
    const oidRes = await fetch(`${SB_URL}/rest/v1/rpc/resolve_lark_open_id`, {
      method: "POST", headers: sbHeaders, body: JSON.stringify({ p_email: email }),
    });
    let ownerId = (await oidRes.json().catch(() => null)) as string | null;
    let ownerFrom = "organizer";
    if (!ownerId && parts.length) { ownerId = parts[0]; ownerFrom = "participant"; }   // 主催者が未連携なら参加者をホストに
    if (!ownerId) { console.log("no-open-id", email); return json({ url: null, reason: "no-open-id", email }); }

    // 2) tenant_access_token
    const tokRes = await fetch(`${LARK}/auth/v3/tenant_access_token/internal`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ app_id: APP_ID, app_secret: APP_SECRET }),
    });
    const tok = await tokRes.json().catch(() => null);
    const token = tok?.tenant_access_token;
    if (!token) { console.log("no-token", JSON.stringify(tok)); return json({ url: null, reason: "no-token", detail: tok }); }

    // 3) VC 予約（owner=主催者 open_id、有効期限=予約終了時刻）
    //    RESTパスの綴り揺れ対策として reserves→reserve の順で試す。
    const attempts: any[] = [];
    for (const path of ["/vc/v1/reserves/apply", "/vc/v1/reserve/apply"]) {
      const res = await tryReserve(path, token, endTime, ownerId, topic);
      attempts.push({ path, status: res.status, code: res.code, msg: res.msg, hasUrl: !!res.url });
      console.log("reserve-try", JSON.stringify(attempts[attempts.length - 1]));
      if (res.code === 0 && res.url) return json({ url: res.url, owner_from: ownerFrom });
      if (res.code === 0 && !res.url) return json({ url: null, reason: "no-url-in-response", detail: res.raw });
    }
    return json({ url: null, reason: "reserve-fail", attempts });
  } catch (e) {
    console.log("error", String(e));
    return json({ url: null, reason: "error", detail: String(e) });
  }
});
