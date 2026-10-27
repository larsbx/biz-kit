-- Non-authoritative discovery projection in the EXISTING governed database.
-- No event payload, grant, execution lease, or backend launch is recorded here.
BEGIN;
CREATE TABLE IF NOT EXISTS agent_ops.event_cursors (
  home_id text NOT NULL CHECK (length(home_id) BETWEEN 1 AND 128),
  subscriber text NOT NULL CHECK (length(subscriber) BETWEEN 1 AND 128),
  global_seq bigint NOT NULL DEFAULT 0 CHECK (global_seq >= 0),
  global_hash bytea,
  PRIMARY KEY (home_id, subscriber),
  CHECK ((global_seq=0 AND global_hash IS NULL) OR
         (global_seq>0 AND global_hash IS NOT NULL AND octet_length(global_hash)=32))
);

-- Each row is the complete discovery bundle for ONE event: either one scoped
-- reconciliation registration or a durable zero-effect processed receipt.
CREATE TABLE IF NOT EXISTS agent_ops.event_registrations (
  home_id text NOT NULL,
  subscriber text NOT NULL,
  global_seq bigint NOT NULL CHECK (global_seq>0),
  event_id text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 128),
  prev_global_hash bytea CHECK (prev_global_hash IS NULL OR octet_length(prev_global_hash)=32),
  event_hash bytea NOT NULL CHECK (octet_length(event_hash)=32),
  effect_id text,
  chapter_id text,
  tenant_id text,
  project_id text,
  PRIMARY KEY (home_id, subscriber, global_seq),
  UNIQUE (home_id, subscriber, event_id),
  UNIQUE (home_id, subscriber, effect_id),
  FOREIGN KEY (home_id, subscriber) REFERENCES agent_ops.event_cursors(home_id, subscriber),
  CHECK ((effect_id IS NULL AND chapter_id IS NULL AND tenant_id IS NULL AND project_id IS NULL)
      OR (effect_id IS NOT NULL AND effect_id='agent-event:' || event_id AND chapter_id IS NOT NULL
          AND length(chapter_id) BETWEEN 1 AND 128
          AND ((tenant_id IS NULL AND project_id IS NULL) OR
               (tenant_id IS NOT NULL AND project_id IS NOT NULL
                AND length(tenant_id) BETWEEN 1 AND 128 AND length(project_id) BETWEEN 1 AND 128))))
);

CREATE OR REPLACE FUNCTION agent_ops.guard_event_cursor()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $body$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.global_seq<>0 OR NEW.global_hash IS NOT NULL THEN
      RAISE EXCEPTION 'cursor must start at zero';
    END IF;
  ELSE
    IF NEW.home_id<>OLD.home_id OR NEW.subscriber<>OLD.subscriber OR
       NEW.global_seq<>OLD.global_seq+1 OR NOT EXISTS (
         SELECT 1 FROM agent_ops.event_registrations r
          WHERE r.home_id=OLD.home_id AND r.subscriber=OLD.subscriber
            AND r.global_seq=NEW.global_seq AND r.event_hash=NEW.global_hash
            AND r.prev_global_hash IS NOT DISTINCT FROM OLD.global_hash
       ) THEN
      RAISE EXCEPTION 'registration must precede contiguous cursor advance';
    END IF;
  END IF;
  RETURN NEW;
END $body$;
DROP TRIGGER IF EXISTS event_cursor_prefix ON agent_ops.event_cursors;
CREATE TRIGGER event_cursor_prefix BEFORE INSERT OR UPDATE ON agent_ops.event_cursors
  FOR EACH ROW EXECUTE FUNCTION agent_ops.guard_event_cursor();

CREATE OR REPLACE FUNCTION agent_ops.commit_event_registration(
  p_home text, p_subscriber text, p_expected_seq bigint, p_expected_hash bytea,
  p_seq bigint, p_event text, p_prev bytea, p_hash bytea,
  p_effect text, p_chapter text, p_tenant text, p_project text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $body$
DECLARE c agent_ops.event_cursors%ROWTYPE;
DECLARE r agent_ops.event_registrations%ROWTYPE;
BEGIN
  IF p_expected_seq IS NULL OR p_expected_seq<0 OR p_seq IS NULL OR
     p_seq<>p_expected_seq+1 OR p_prev IS DISTINCT FROM p_expected_hash THEN
    RAISE EXCEPTION 'noncontiguous registration' USING ERRCODE='40001';
  END IF;
  INSERT INTO agent_ops.event_cursors(home_id,subscriber) VALUES(p_home,p_subscriber)
    ON CONFLICT DO NOTHING;
  SELECT * INTO STRICT c FROM agent_ops.event_cursors
    WHERE home_id=p_home AND subscriber=p_subscriber FOR UPDATE;

  IF c.global_seq>=p_seq THEN
    SELECT * INTO r FROM agent_ops.event_registrations
      WHERE home_id=p_home AND subscriber=p_subscriber AND global_seq=p_seq;
    IF FOUND AND ROW(r.event_id,r.prev_global_hash,r.event_hash,r.effect_id,r.chapter_id,r.tenant_id,r.project_id)
      IS NOT DISTINCT FROM ROW(p_event,p_prev,p_hash,p_effect,p_chapter,p_tenant,p_project) THEN
      RETURN 'existing';
    END IF;
    RAISE EXCEPTION 'registration identity conflict' USING ERRCODE='40001';
  END IF;
  IF c.global_seq<>p_expected_seq OR c.global_hash IS DISTINCT FROM p_expected_hash THEN
    RAISE EXCEPTION 'cursor compare-and-swap refused' USING ERRCODE='40001';
  END IF;

  -- This INSERT (including the zero-effect receipt) MUST precede UPDATE.
  INSERT INTO agent_ops.event_registrations
    (home_id,subscriber,global_seq,event_id,prev_global_hash,event_hash,
     effect_id,chapter_id,tenant_id,project_id)
    VALUES(p_home,p_subscriber,p_seq,p_event,p_prev,p_hash,p_effect,p_chapter,p_tenant,p_project);
  UPDATE agent_ops.event_cursors SET global_seq=p_seq,global_hash=p_hash
    WHERE home_id=p_home AND subscriber=p_subscriber;
  RETURN 'new';
END $body$;

-- Execute only through a trusted host role; the migration owner must be a
-- distinct protected role. Never grant cursor UPDATE/registration DML to it.
REVOKE ALL ON agent_ops.event_cursors, agent_ops.event_registrations FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_ops.guard_event_cursor() FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_ops.commit_event_registration(text,text,bigint,bytea,bigint,text,bytea,bytea,text,text,text,text) FROM PUBLIC;
COMMENT ON TABLE agent_ops.event_registrations IS
  'Rebuildable discovery effects/processed receipts; not signed business authority or execution permission.';
COMMIT;
