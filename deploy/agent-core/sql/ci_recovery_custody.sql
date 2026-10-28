-- Disposable PostgreSQL contract only. Synthetic receipts below model a
-- trusted verifier; they do NOT constitute live backend conformance evidence.
\set ON_ERROR_STOP on

DO $test$
DECLARE token bytea := sha256(convert_to('host-token','UTF8')); n integer;
BEGIN
  INSERT INTO agent_ops.execution_attempts(effect_id,intent_event_id,chapter_id,tenant_id,project_id,
    run_id,task_id,task_version,task_source_event_id,definition_digest,execution_profile_id,
    execution_profile_digest,max_duration_ms,max_output_bytes,descriptor_digest)
  VALUES('agent-run:custody-test','custody-test','chapter','tenant','project','custody-run','task',3,'source',
    sha256('definition'::bytea),'approved',sha256('profile'::bytea),30000,8,sha256('descriptor'::bytea));
  PERFORM * FROM agent_ops.claim_attempt('agent-run:custody-test',1,'worker',token,60000,2);
  IF NOT EXISTS(SELECT 1 FROM agent_ops.execution_attempts WHERE effect_id='agent-run:custody-test'
      AND lease_expires_at<=execution_deadline) THEN RAISE EXCEPTION 'claim exceeded duration budget'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',NULL,1,token,'output'::bytea);
  IF n<>0 THEN RAISE EXCEPTION 'null CAS version bypassed custody'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',2,1,sha256('wrong'::bytea),'output'::bytea);
  IF n<>0 THEN RAISE EXCEPTION 'wrong token stored output'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',2,1,token,'oversized'::bytea);
  IF n<>0 OR EXISTS(SELECT 1 FROM agent_ops.candidate_custody WHERE effect_id='agent-run:custody-test')
     THEN RAISE EXCEPTION 'oversized output left custody'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',2,1,token,'output'::bytea);
  IF n<>1 THEN RAISE EXCEPTION 'valid candidate not committed'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',2,1,token,'output'::bytea);
  IF n<>1 THEN RAISE EXCEPTION 'lost custody acknowledgement was not idempotent'; END IF;
  IF NOT EXISTS(SELECT 1 FROM agent_ops.candidate_custody c JOIN agent_ops.execution_attempts a USING(effect_id)
      WHERE a.effect_id='agent-run:custody-test' AND a.phase='candidate_ready' AND a.row_version=3
        AND a.tenant_id='tenant' AND c.bytes='output'::bytea AND c.digest=sha256(c.bytes)
        AND c.digest=a.candidate_digest) THEN RAISE EXCEPTION 'custody lost bytes/scope/digest'; END IF;
  SELECT count(*) INTO n FROM agent_ops.commit_candidate('agent-run:custody-test',2,1,token,'changed'::bytea);
  IF n<>0 THEN RAISE EXCEPTION 'duplicate/stale delivery replaced result'; END IF;
  BEGIN
    UPDATE agent_ops.candidate_custody SET bytes='tampered'::bytea WHERE effect_id='agent-run:custody-test';
    RAISE EXCEPTION 'tampered custody bytes accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END;
$test$;

DO $test$
DECLARE old_token bytea := sha256('old'::bytea); new_token bytea := sha256('new'::bytea); n integer;
BEGIN
  INSERT INTO agent_ops.execution_attempts(effect_id,intent_event_id,chapter_id,tenant_id,project_id,
    run_id,task_id,task_version,task_source_event_id,definition_digest,execution_profile_id,
    execution_profile_digest,max_duration_ms,max_output_bytes,descriptor_digest)
  VALUES('agent-run:recover-test','recover-test','chapter','tenant','project','recover-run','task',3,'source',
    sha256('definition'::bytea),'approved',sha256('profile'::bytea),30000,4096,sha256('descriptor'::bytea));
  PERFORM * FROM agent_ops.claim_attempt('agent-run:recover-test',1,'old-worker',old_token,5000,2);
  -- Crash before attachment: lookup by effect recovers the handle and fences the old token.
  UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second'
    WHERE effect_id='agent-run:recover-test';
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:recover-test',NULL,1,'running','backend',
    'receipt-running'::bytea,'new-worker',new_token,5000,NULL);
  IF n<>0 THEN RAISE EXCEPTION 'null recovery version bypassed CAS'; END IF;
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:recover-test',2,1,'running','backend',
    'receipt-running'::bytea,'new-worker',new_token,5000,NULL);
  IF n<>1 THEN RAISE EXCEPTION 'abandoned execution not adopted'; END IF;
  IF NOT EXISTS(SELECT 1 FROM agent_ops.execution_attempts WHERE effect_id='agent-run:recover-test'
      AND attempt_epoch=2 AND attempts=1 AND row_version=3 AND backend_ref='backend'
      AND lease_expires_at<=execution_deadline) THEN RAISE EXCEPTION 'adoption relaunched/reset budget'; END IF;
  SELECT count(*) INTO n FROM agent_ops.renew_attempt('agent-run:recover-test',3,1,old_token,5000);
  IF n<>0 THEN RAISE EXCEPTION 'old owner retained authority'; END IF;
  UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second'
    WHERE effect_id='agent-run:recover-test';
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:recover-test',3,2,'running','other-backend',
    'wrong-backend-receipt'::bytea,'worker',new_token,5000,NULL);
  IF n<>0 THEN RAISE EXCEPTION 'backend identity was rebound'; END IF;
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:recover-test',3,2,'running','backend',
    'receipt-running'::bytea,'worker',new_token,5000,NULL);
  IF n<>0 THEN RAISE EXCEPTION 'receipt replayed across generations'; END IF;
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:recover-test',3,2,'candidate','backend',
    'receipt-candidate'::bytea,'worker',new_token,5000,'recovered output'::bytea);
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM agent_ops.candidate_custody WHERE effect_id='agent-run:recover-test'
      AND epoch=2 AND bytes='recovered output'::bytea) THEN RAISE EXCEPTION 'lost result not recovered'; END IF;
END;
$test$;

DO $test$
DECLARE token bytea := sha256('retry-token'::bytea); n integer; original_deadline timestamptz;
BEGIN
  INSERT INTO agent_ops.execution_attempts(effect_id,intent_event_id,chapter_id,tenant_id,project_id,
    run_id,task_id,task_version,task_source_event_id,definition_digest,execution_profile_id,
    execution_profile_digest,max_duration_ms,max_output_bytes,descriptor_digest)
  VALUES('agent-run:absence-test','absence-test','chapter','tenant','project','absence-run','task',3,'source',
    sha256('definition'::bytea),'approved',sha256('profile'::bytea),30000,4096,sha256('descriptor'::bytea));
  PERFORM * FROM agent_ops.claim_attempt('agent-run:absence-test',1,'worker',token,5000,2);
  SELECT execution_deadline INTO original_deadline FROM agent_ops.execution_attempts WHERE effect_id='agent-run:absence-test';
  UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second'
    WHERE effect_id='agent-run:absence-test';
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:absence-test',2,1,'absent',NULL,
    'final-absence-receipt'::bytea,'worker',token,5000,NULL);
  IF n<>1 THEN RAISE EXCEPTION 'verified absence failed to release pending effect'; END IF;
  PERFORM * FROM agent_ops.claim_attempt('agent-run:absence-test',3,'worker',token,60000,2);
  IF NOT EXISTS(SELECT 1 FROM agent_ops.execution_attempts WHERE effect_id='agent-run:absence-test'
      AND row_version=4 AND attempt_epoch=2 AND execution_deadline=original_deadline
      AND lease_expires_at<=execution_deadline) THEN RAISE EXCEPTION 'retry reset duration budget'; END IF;
  UPDATE agent_ops.execution_attempts SET execution_deadline=clock_timestamp()-interval '1 second',
    lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id='agent-run:absence-test';
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:absence-test',4,2,'running','backend',
    'late-running'::bytea,'worker',token,5000,NULL);
  IF n<>0 THEN RAISE EXCEPTION 'exhausted run was adopted'; END IF;
  PERFORM * FROM agent_ops.request_cancel('agent-run:absence-test',4);
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:absence-test',5,3,'candidate','backend',
    'late-candidate'::bytea,'worker',token,5000,'late'::bytea);
  IF n<>0 THEN RAISE EXCEPTION 'candidate bypassed cancellation'; END IF;
  SELECT count(*) INTO n FROM agent_ops.apply_recovery('agent-run:absence-test',5,3,'cancelled','backend',
    'terminated-receipt'::bytea,'worker',token,5000,NULL);
  IF n<>1 OR NOT EXISTS(SELECT 1 FROM agent_ops.execution_attempts WHERE effect_id='agent-run:absence-test'
      AND phase='cancelled' AND row_version=6 AND cancellation_receipt_id IS NOT NULL)
      THEN RAISE EXCEPTION 'verified cancellation was not persisted'; END IF;
END;
$test$;
