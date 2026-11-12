-- LUXURY WRIST BRAND ERP — TEAM CHAT (live chat for every login, like a WhatsApp group)
--
-- Mohit asked (12 Nov 2026): every login (Admin, Sales Head, Salesman, Godown, Accounts, Driver ...)
-- can chat live from a round chat button in the corner of every page / the phone app.
--   * Tag one person (@Harsh) = a PERSONAL chat between the two of them only.
--   * @All Team / @All Sales Team / @All Drivers ... = a GROUP: everyone in it sees it and can reply.
--   * @name inside a group highlights the message for that person.
--   * Admin sees every chat (who talked to whom, what), only looks (cannot write in others' chats).
--   * Chats are never deleted by themselves; only Admin deletes (one message or a whole chat).
-- A new message makes ONE unread CHAT_MSG bell row per chat per person (phone push, lwb_web_push_setup.sql);
-- more messages in the same chat do not make more rows until the person reads the chat.
-- The bell panel itself hides CHAT_MSG rows (the chat button shows them).
--
-- Chat only. Orders, stock, bills, payments and Tally are NOT changed. Safe to run again.

BEGIN;

ALTER TABLE public.erp_notifications ADD COLUMN IF NOT EXISTS ref_type text;
ALTER TABLE public.erp_notifications ADD COLUMN IF NOT EXISTS ref_id text;
CREATE INDEX IF NOT EXISTS erp_notifications_ref_idx ON public.erp_notifications (ref_type, ref_id) WHERE ref_type IS NOT NULL;

-- Logged-in active user's role ('' when not active).
CREATE OR REPLACE FUNCTION public.lwb_chat_my_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_chat_role_label(p_role text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE lower(btrim(coalesce(p_role,'')))
    WHEN 'admin' THEN 'Admin' WHEN 'manager' THEN 'Sales Head' WHEN 'warehouse' THEN 'Godown Manager'
    WHEN 'accounts' THEN 'Accounts' WHEN 'sales' THEN 'Salesman' WHEN 'driver' THEN 'Driver'
    WHEN 'transport' THEN 'Transport' ELSE initcap(coalesce(p_role,'')) END;
$fn$;

CREATE TABLE IF NOT EXISTS public.lwb_chat_rooms (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('DIRECT','GROUP')),
  gkey text UNIQUE,                 -- GROUP: ALL / SALES / DRIVERS / GODOWN / ACCOUNTS
  name text,                        -- GROUP: "@All Team" ...
  roles text[],                     -- GROUP: roles in it (Admin and Sales Head are in every group); NULL = everyone
  user_a uuid,                      -- DIRECT: the two people, user_a < user_b
  user_b uuid,
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_at timestamptz,
  last_text text,
  last_by_name text,
  CHECK (kind = 'GROUP' OR (user_a IS NOT NULL AND user_b IS NOT NULL AND user_a < user_b))
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_chat_rooms_pair_uidx ON public.lwb_chat_rooms(user_a, user_b) WHERE kind = 'DIRECT';

CREATE TABLE IF NOT EXISTS public.lwb_chat_messages (
  id bigserial PRIMARY KEY,
  room_id bigint NOT NULL REFERENCES public.lwb_chat_rooms(id) ON DELETE CASCADE,
  sender uuid NOT NULL DEFAULT auth.uid(),
  sender_name text,
  sender_role text,
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  mentions uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_chat_messages_room_idx ON public.lwb_chat_messages(room_id, id DESC);

CREATE TABLE IF NOT EXISTS public.lwb_chat_reads (
  room_id bigint NOT NULL REFERENCES public.lwb_chat_rooms(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  last_read_id bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (room_id, user_id)
);

INSERT INTO public.lwb_chat_rooms(kind, gkey, name, roles, created_by) VALUES
  ('GROUP','ALL','@All Team',NULL,NULL),
  ('GROUP','SALES','@All Sales Team',ARRAY['sales'],NULL),
  ('GROUP','DRIVERS','@All Drivers',ARRAY['driver','transport'],NULL),
  ('GROUP','GODOWN','@All Godown',ARRAY['warehouse'],NULL),
  ('GROUP','ACCOUNTS','@All Accounts',ARRAY['accounts'],NULL)
ON CONFLICT (gkey) DO NOTHING;

-- Is this user (active) a member of the chat?
CREATE OR REPLACE FUNCTION public.lwb_chat_member(p_room bigint, p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.lwb_chat_rooms r
    JOIN public.user_profiles p ON p.id = p_user AND p.active = true
    WHERE r.id = p_room AND (
      (r.kind = 'DIRECT' AND p_user IN (r.user_a, r.user_b))
      OR (r.kind = 'GROUP' AND (r.roles IS NULL OR lower(btrim(p.role)) IN ('admin','manager')
                                OR lower(btrim(p.role)) = ANY (r.roles)))));
$fn$;

-- Can the logged-in user read the chat: a member, or Admin (Admin sees every chat).
CREATE OR REPLACE FUNCTION public.lwb_chat_can_see(p_room bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_chat_my_role() = 'admin' OR public.lwb_chat_member(p_room, auth.uid());
$fn$;

REVOKE ALL ON FUNCTION public.lwb_chat_my_role(), public.lwb_chat_member(bigint,uuid), public.lwb_chat_can_see(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_chat_my_role(), public.lwb_chat_can_see(bigint), public.lwb_chat_role_label(text) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_chat_member(bigint,uuid) FROM authenticated;

ALTER TABLE public.lwb_chat_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_chat_reads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_chat_rooms_read ON public.lwb_chat_rooms;
CREATE POLICY lwb_chat_rooms_read ON public.lwb_chat_rooms FOR SELECT TO authenticated USING (public.lwb_chat_can_see(id));
DROP POLICY IF EXISTS lwb_chat_messages_read ON public.lwb_chat_messages;
CREATE POLICY lwb_chat_messages_read ON public.lwb_chat_messages FOR SELECT TO authenticated USING (public.lwb_chat_can_see(room_id));
DROP POLICY IF EXISTS lwb_chat_reads_read ON public.lwb_chat_reads;
CREATE POLICY lwb_chat_reads_read ON public.lwb_chat_reads FOR SELECT TO authenticated USING (user_id = auth.uid());
REVOKE ALL ON TABLE public.lwb_chat_rooms, public.lwb_chat_messages, public.lwb_chat_reads FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_chat_rooms, public.lwb_chat_messages, public.lwb_chat_reads TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_chat_rooms_id_seq, public.lwb_chat_messages_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- People to chat with / tag: every active login except me.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_people()
RETURNS TABLE(id uuid, name text, role text, role_label text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_chat_my_role() = '' THEN RAISE EXCEPTION 'Your login is not active.'; END IF;
  RETURN QUERY
  SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'User')::text, lower(btrim(p.role))::text, public.lwb_chat_role_label(p.role)
  FROM public.user_profiles p
  WHERE p.active = true AND p.id <> auth.uid()
  ORDER BY lower(coalesce(p.full_name,''));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Personal chat with one person: opens the old one or makes it. Returns the chat id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_open_direct(p_user uuid)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE a uuid; b uuid; v bigint;
BEGIN
  IF public.lwb_chat_my_role() = '' THEN RAISE EXCEPTION 'Your login is not active.'; END IF;
  IF p_user IS NULL OR p_user = auth.uid() THEN RAISE EXCEPTION 'Pick another person to chat with.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = p_user AND active = true) THEN
    RAISE EXCEPTION 'This person''s login is not active.';
  END IF;
  a := least(auth.uid(), p_user); b := greatest(auth.uid(), p_user);
  SELECT id INTO v FROM public.lwb_chat_rooms WHERE kind = 'DIRECT' AND user_a = a AND user_b = b;
  IF v IS NULL THEN
    INSERT INTO public.lwb_chat_rooms(kind, user_a, user_b) VALUES ('DIRECT', a, b)
    ON CONFLICT (user_a, user_b) WHERE kind = 'DIRECT' DO NOTHING RETURNING id INTO v;
    IF v IS NULL THEN SELECT id INTO v FROM public.lwb_chat_rooms WHERE kind = 'DIRECT' AND user_a = a AND user_b = b; END IF;
  END IF;
  RETURN v;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Send a message. p_mentions = people tagged with @name (only members of the chat are kept).
-- Only members write (Admin only looks at other people's chats). Returns the message id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_send(p_room bigint, p_body text, p_mentions uuid[] DEFAULT '{}')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r public.lwb_chat_rooms; me public.user_profiles; v_body text; v_id bigint; v_m uuid[]; v_title text;
BEGIN
  SELECT * INTO me FROM public.user_profiles WHERE id = auth.uid() AND active = true;
  IF me.id IS NULL THEN RAISE EXCEPTION 'Your login is not active.'; END IF;
  SELECT * INTO r FROM public.lwb_chat_rooms WHERE id = p_room;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Chat not found.'; END IF;
  IF NOT public.lwb_chat_member(r.id, me.id) THEN
    RAISE EXCEPTION 'You can only look at this chat. You are not in it.';
  END IF;
  v_body := btrim(coalesce(p_body,''));
  IF v_body = '' THEN RAISE EXCEPTION 'Type a message.'; END IF;
  IF length(v_body) > 2000 THEN RAISE EXCEPTION 'Message is too long (2000 letters at most).'; END IF;
  SELECT coalesce(array_agg(DISTINCT m), '{}') INTO v_m
  FROM unnest(coalesce(p_mentions,'{}'::uuid[])) m
  WHERE m <> me.id AND public.lwb_chat_member(r.id, m);

  INSERT INTO public.lwb_chat_messages(room_id, sender, sender_name, sender_role, body, mentions)
  VALUES (r.id, me.id, coalesce(nullif(btrim(me.full_name),''),'User'), lower(btrim(me.role)), v_body, v_m)
  RETURNING id INTO v_id;
  UPDATE public.lwb_chat_rooms SET last_at = now(), last_text = left(v_body, 120),
    last_by_name = coalesce(nullif(btrim(me.full_name),''),'User') WHERE id = r.id;
  INSERT INTO public.lwb_chat_reads(room_id, user_id, last_read_id) VALUES (r.id, me.id, v_id)
  ON CONFLICT (room_id, user_id) DO UPDATE SET last_read_id = greatest(public.lwb_chat_reads.last_read_id, excluded.last_read_id);

  -- One unread CHAT_MSG bell per chat per person (phone push). Tagged people always get one.
  v_title := CASE WHEN r.kind = 'DIRECT' THEN 'Chat: ' || coalesce(nullif(btrim(me.full_name),''),'User')
                  ELSE r.name || ' · ' || coalesce(nullif(btrim(me.full_name),''),'User') END;
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p.id,
    left(CASE WHEN p.id = ANY (v_m) THEN '@ ' ELSE '' END || v_title, 150),
    left(v_body, 300), 'CHAT_MSG', 'CHAT', r.id::text
  FROM public.user_profiles p
  WHERE p.active = true AND p.id <> me.id AND public.lwb_chat_member(r.id, p.id)
    AND (p.id = ANY (v_m) OR NOT EXISTS (
      SELECT 1 FROM public.erp_notifications n WHERE n.user_id = p.id AND n.ref_type = 'CHAT'
        AND n.ref_id = r.id::text AND n.notification_type = 'CHAT_MSG' AND n.is_read = false));
  RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Mark a chat read (up to the newest message). Also closes its CHAT_MSG bells.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_read(p_room bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v bigint;
BEGIN
  IF NOT public.lwb_chat_member(p_room, auth.uid()) THEN RETURN; END IF;
  SELECT coalesce(max(id),0) INTO v FROM public.lwb_chat_messages WHERE room_id = p_room;
  INSERT INTO public.lwb_chat_reads(room_id, user_id, last_read_id) VALUES (p_room, auth.uid(), v)
  ON CONFLICT (room_id, user_id) DO UPDATE SET last_read_id = greatest(public.lwb_chat_reads.last_read_id, excluded.last_read_id);
  UPDATE public.erp_notifications SET is_read = true
  WHERE user_id = auth.uid() AND ref_type = 'CHAT' AND ref_id = p_room::text AND notification_type = 'CHAT_MSG' AND is_read = false;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Chat list. p_all = false: my chats (groups I am in + my personal chats), with unread count.
-- p_all = true (Admin only): every personal chat of other people ("Everyone's chats").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_rooms_list(p_all boolean DEFAULT false)
RETURNS TABLE(id bigint, kind text, name text, sub text, other_id uuid, other_role text,
              last_at timestamptz, last_text text, last_by_name text, unread integer, mention boolean, member boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_chat_my_role();
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Your login is not active.'; END IF;
  IF p_all AND v_role <> 'admin' THEN RAISE EXCEPTION 'Only Admin can see everyone''s chats.'; END IF;
  RETURN QUERY
  WITH rr AS (
    SELECT r.* FROM public.lwb_chat_rooms r
    WHERE CASE WHEN p_all THEN r.kind = 'DIRECT' AND auth.uid() NOT IN (r.user_a, r.user_b) AND r.last_at IS NOT NULL
               ELSE public.lwb_chat_member(r.id, auth.uid()) AND (r.kind = 'GROUP' OR r.last_at IS NOT NULL) END
  )
  SELECT rr.id, rr.kind,
    CASE WHEN rr.kind = 'GROUP' THEN rr.name
         WHEN p_all THEN coalesce(pa.full_name,'User') || ' ↔ ' || coalesce(pb.full_name,'User')
         WHEN rr.user_a = auth.uid() THEN coalesce(pb.full_name,'User') ELSE coalesce(pa.full_name,'User') END::text,
    CASE WHEN rr.kind = 'GROUP' THEN
           (SELECT count(*) FROM public.user_profiles p WHERE p.active = true AND public.lwb_chat_member(rr.id, p.id))::text || ' people'
         WHEN p_all THEN public.lwb_chat_role_label(pa.role) || ' ↔ ' || public.lwb_chat_role_label(pb.role)
         WHEN rr.user_a = auth.uid() THEN public.lwb_chat_role_label(pb.role) ELSE public.lwb_chat_role_label(pa.role) END::text,
    CASE WHEN rr.kind = 'DIRECT' AND NOT p_all THEN CASE WHEN rr.user_a = auth.uid() THEN rr.user_b ELSE rr.user_a END END,
    CASE WHEN rr.kind = 'DIRECT' AND NOT p_all THEN lower(btrim(CASE WHEN rr.user_a = auth.uid() THEN pb.role ELSE pa.role END)) END::text,
    rr.last_at, rr.last_text, rr.last_by_name,
    CASE WHEN p_all THEN 0 ELSE (SELECT count(*)::int FROM public.lwb_chat_messages m
      WHERE m.room_id = rr.id AND m.sender <> auth.uid()
        AND m.id > coalesce((SELECT x.last_read_id FROM public.lwb_chat_reads x WHERE x.room_id = rr.id AND x.user_id = auth.uid()),0)) END,
    CASE WHEN p_all THEN false ELSE EXISTS (SELECT 1 FROM public.lwb_chat_messages m
      WHERE m.room_id = rr.id AND auth.uid() = ANY (m.mentions)
        AND m.id > coalesce((SELECT x.last_read_id FROM public.lwb_chat_reads x WHERE x.room_id = rr.id AND x.user_id = auth.uid()),0)) END,
    NOT p_all
  FROM rr
  LEFT JOIN public.user_profiles pa ON pa.id = rr.user_a
  LEFT JOIN public.user_profiles pb ON pb.id = rr.user_b
  ORDER BY rr.last_at DESC NULLS LAST, rr.id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Admin deletes: one message (p_message) or every message of a chat (p_message NULL;
-- a personal chat itself is removed too). Nothing is deleted by itself.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_chat_delete(p_room bigint, p_message bigint DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE n integer; r public.lwb_chat_rooms; lm public.lwb_chat_messages;
BEGIN
  IF public.lwb_chat_my_role() <> 'admin' THEN RAISE EXCEPTION 'Only Admin can delete chats.'; END IF;
  SELECT * INTO r FROM public.lwb_chat_rooms WHERE id = p_room;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Chat not found.'; END IF;
  IF p_message IS NOT NULL THEN
    DELETE FROM public.lwb_chat_messages WHERE id = p_message AND room_id = r.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT * INTO lm FROM public.lwb_chat_messages WHERE room_id = r.id ORDER BY id DESC LIMIT 1;
    UPDATE public.lwb_chat_rooms SET last_at = lm.created_at, last_text = left(lm.body,120), last_by_name = lm.sender_name WHERE id = r.id;
  ELSE
    DELETE FROM public.lwb_chat_messages WHERE room_id = r.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF r.kind = 'DIRECT' THEN DELETE FROM public.lwb_chat_rooms WHERE id = r.id;
    ELSE UPDATE public.lwb_chat_rooms SET last_at = NULL, last_text = NULL, last_by_name = NULL WHERE id = r.id; END IF;
  END IF;
  IF p_message IS NULL THEN
    DELETE FROM public.erp_notifications WHERE ref_type = 'CHAT' AND ref_id = r.id::text AND notification_type = 'CHAT_MSG';
  END IF;
  RETURN n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_chat_people(), public.lwb_chat_open_direct(uuid), public.lwb_chat_send(bigint,text,uuid[]),
  public.lwb_chat_read(bigint), public.lwb_chat_rooms_list(boolean), public.lwb_chat_delete(bigint,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_chat_people(), public.lwb_chat_open_direct(uuid), public.lwb_chat_send(bigint,text,uuid[]),
  public.lwb_chat_read(bigint), public.lwb_chat_rooms_list(boolean), public.lwb_chat_delete(bigint,bigint) TO authenticated;

-- Live messages: the chat button listens to new rows (Supabase Realtime keeps the read rule above).
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
                     WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'lwb_chat_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.lwb_chat_messages;
  END IF;
END
$do$;

COMMIT;
