\set ON_ERROR_STOP on
BEGIN;
INSERT INTO agent_ops.event_effect_registrations
  (subscription_name,event_id,global_seq,event_hash,effect_id,chapter_id,tenant_id,project_id)
  VALUES ('native-ci','event-1',1,decode(repeat('11',32),'hex'),'agent-event:event-1','chapter','tenant','project')
  ON CONFLICT DO NOTHING;
INSERT INTO agent_ops.event_effect_registrations
  (subscription_name,event_id,global_seq,event_hash,effect_id,chapter_id,tenant_id,project_id)
  VALUES ('native-ci','event-1',1,decode(repeat('11',32),'hex'),'agent-event:event-1','chapter','tenant','project')
  ON CONFLICT DO NOTHING;
DO $contract$
BEGIN
  IF (SELECT count(*) FROM agent_ops.event_effect_registrations WHERE subscription_name='native-ci')<>1 THEN
    RAISE EXCEPTION 'duplicate registration';
  END IF;
  BEGIN
    INSERT INTO agent_ops.event_effect_registrations(subscription_name,event_id,global_seq,event_hash,chapter_id)
      VALUES ('bad-ci','event-2',2,decode(repeat('22',32),'hex'),'partial-no-op');
    RAISE EXCEPTION 'malformed no-op accepted';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $contract$;
CREATE ROLE agent_effect_contract;
GRANT USAGE ON SCHEMA agent_ops TO agent_effect_contract;
GRANT SELECT,INSERT ON agent_ops.event_effect_registrations TO agent_effect_contract;
SET LOCAL ROLE agent_effect_contract;
INSERT INTO agent_ops.event_effect_registrations(subscription_name,event_id,global_seq,event_hash)
  VALUES ('role-ci','no-op',1,decode(repeat('33',32),'hex'));
DO $contract$
BEGIN
  BEGIN
    DELETE FROM agent_ops.event_effect_registrations WHERE subscription_name='role-ci';
    RAISE EXCEPTION 'host obtained effect deletion';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE agent_ops.event_effect_registrations SET global_seq=2 WHERE subscription_name='role-ci';
    RAISE EXCEPTION 'host obtained effect mutation';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $contract$;
RESET ROLE;
ROLLBACK;
-- A durable effect receipt, not a second delivery checkpoint.
INSERT INTO agent_ops.event_effect_registrations(subscription_name,event_id,global_seq,event_hash)
  VALUES ('volume-ci','volume-event',1,decode(repeat('44',32),'hex')) ON CONFLICT DO NOTHING;
