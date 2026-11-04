// Supabase Edge Function: staff-accounts
// Creates sign-in accounts for active staff on the Parking Ops staff list, so public
// sign-up can stay OFF. Only Parking Ops managers (public.ops_admins) can call it.
// Called by ucaps-parking-ops.html after adding/importing staff and when a manager opens the app.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 1. Caller must be a signed-in Parking Ops manager
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    const email = who?.user?.email?.toLowerCase();
    if (whoErr || !email) return json({ error: "Not signed in" }, 401);
    const { data: mgr } = await admin.from("ops_admins").select("id").eq("email", email).maybeSingle();
    if (!mgr) return json({ error: "Managers only" }, 403);

    // 2. Active staff emails
    const { data: staff, error: sErr } = await admin.from("staff_members").select("email").eq("active", true);
    if (sErr) throw sErr;
    const wanted = new Set((staff || []).map((s: { email: string }) => s.email.toLowerCase()));

    // 3. Existing auth accounts
    const have = new Set<string>();
    for (let page = 1; ; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) throw error;
      data.users.forEach((u) => u.email && have.add(u.email.toLowerCase()));
      if (data.users.length < 1000) break;
    }

    // 4. Create the missing ones (email pre-confirmed; they sign in with an emailed code)
    const created: string[] = [], failed: { email: string; error: string }[] = [];
    for (const e of wanted) {
      if (have.has(e)) continue;
      const { error } = await admin.auth.admin.createUser({ email: e, email_confirm: true });
      if (error && !/already/i.test(error.message)) failed.push({ email: e, error: error.message });
      else { created.push(e); have.add(e); }
    }
    const ready = [...wanted].filter((e) => have.has(e));
    return json({ created, failed, ready, total: wanted.size });
  } catch (err) {
    return json({ error: String((err as Error)?.message || err) }, 500);
  }
});
