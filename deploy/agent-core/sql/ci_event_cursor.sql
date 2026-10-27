\set ON_ERROR_STOP on
BEGIN;
DO $contract$
DECLARE h1 bytea:=decode(repeat('11',32),'hex');
DECLARE h2 bytea:=decode(repeat('22',32),'hex');
DECLARE result text;
BEGIN
  SELECT agent_ops.commit_event_registration('cursor-ci','agent-v1',0,NULL,1,'event-1',NULL,h1,
    'agent-event:event-1','chapter','tenant','project') INTO result;
  IF result<>'new' THEN RAISE EXCEPTION 'first registration missing'; END IF;
  SELECT agent_ops.commit_event_registration('cursor-ci','agent-v1',0,NULL,1,'event-1',NULL,h1,
    'agent-event:event-1','chapter','tenant','project') INTO result;
  IF result<>'existing' THEN RAISE EXCEPTION 'duplicate not idempotent'; END IF;
  BEGIN
    PERFORM agent_ops.commit_event_registration('cursor-ci','agent-v1',0,NULL,1,'event-1',NULL,h2,
      'agent-event:event-1','chapter','tenant','project');
    RAISE EXCEPTION 'conflicting duplicate accepted';
  EXCEPTION WHEN serialization_failure THEN NULL; END;
  BEGIN
    PERFORM agent_ops.commit_event_registration('malformed-ci','agent-v1',0,NULL,1,'bad-event',NULL,h1,
      NULL,'chapter',NULL,NULL);
    RAISE EXCEPTION 'partial no-op shape accepted';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    PERFORM agent_ops.commit_event_registration('cursor-ci','agent-v1',2,h2,3,'event-3',h2,h2,
      NULL,NULL,NULL,NULL);
    RAISE EXCEPTION 'gap accepted';
  EXCEPTION WHEN serialization_failure THEN NULL; END;
  BEGIN
    UPDATE agent_ops.event_cursors SET global_seq=2,global_hash=h2 WHERE home_id='cursor-ci';
    RAISE EXCEPTION 'cursor-first negative control survived';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'registration must precede contiguous cursor advance' THEN RAISE; END IF;
  END;
END $contract$;

-- Abort after registration INSERT but before cursor UPDATE. The enclosing SQL
-- statement must roll back both, including under an outer transaction.
CREATE FUNCTION pg_temp.fail_cursor_update() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN RAISE EXCEPTION 'injected cursor boundary failure'; END $body$;
CREATE TRIGGER inject_cursor_failure AFTER UPDATE ON agent_ops.event_cursors
  FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_cursor_update();
DO $contract$
BEGIN
  BEGIN
    PERFORM agent_ops.commit_event_registration('cursor-ci','agent-v1',1,decode(repeat('11',32),'hex'),
      2,'event-2',decode(repeat('11',32),'hex'),decode(repeat('22',32),'hex'),NULL,NULL,NULL,NULL);
    RAISE EXCEPTION 'fault did not fire';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'injected cursor boundary failure' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM agent_ops.event_registrations WHERE home_id='cursor-ci' AND global_seq=2)
     OR (SELECT global_seq FROM agent_ops.event_cursors WHERE home_id='cursor-ci')<>1 THEN
    RAISE EXCEPTION 'partial transaction survived';
  END IF;
END $contract$;
DROP TRIGGER inject_cursor_failure ON agent_ops.event_cursors;
SELECT agent_ops.commit_event_registration('cursor-ci','agent-v1',1,decode(repeat('11',32),'hex'),
  2,'event-2',decode(repeat('11',32),'hex'),decode(repeat('22',32),'hex'),NULL,NULL,NULL,NULL);
DO $contract$
BEGIN
  IF (SELECT count(*) FROM agent_ops.event_registrations WHERE home_id='cursor-ci')<>2 OR
     (SELECT global_seq FROM agent_ops.event_cursors WHERE home_id='cursor-ci')<>2 THEN
    RAISE EXCEPTION 'no-op receipt did not checkpoint';
  END IF;
END $contract$;

CREATE ROLE agent_cursor_contract;
GRANT USAGE ON SCHEMA agent_ops TO agent_cursor_contract;
GRANT SELECT ON agent_ops.event_cursors,agent_ops.event_registrations TO agent_cursor_contract;
GRANT EXECUTE ON FUNCTION agent_ops.commit_event_registration(text,text,bigint,bytea,bigint,text,bytea,bytea,text,text,text,text) TO agent_cursor_contract;
SET LOCAL ROLE agent_cursor_contract;
SELECT agent_ops.commit_event_registration('role-ci','agent-v1',0,NULL,1,'role-event',NULL,
  decode(repeat('33',32),'hex'),NULL,NULL,NULL,NULL);
DO $contract$
BEGIN
  BEGIN
    UPDATE agent_ops.event_cursors SET global_seq=2 WHERE home_id='role-ci';
    RAISE EXCEPTION 'host obtained direct cursor write';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    DELETE FROM agent_ops.event_registrations WHERE home_id='role-ci';
    RAISE EXCEPTION 'host obtained registration deletion';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $contract$;
RESET ROLE;
-- Test data/role/temporary trigger function vanish; migration itself persists.
ROLLBACK;

-- Re-read this durable registration and cursor after container recreation.
SELECT agent_ops.commit_event_registration('cursor-volume-ci','agent-v1',0,NULL,1,'volume-event',NULL,
  decode(repeat('44',32),'hex'),'agent-event:volume-event','chapter','tenant','project');
