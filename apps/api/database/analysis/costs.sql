-- 2026-11-03: 012_analysis_costs.sql이 003 인증 권한 준비 후 호출한다.
-- 비용은 원화 백만분의 일 단위 정수다. 결과 삭제·인증 종료와 FK로 묶지 않는다.
CREATE TABLE payse.analysis_cost_projects (
  project_id text PRIMARY KEY CHECK (length(project_id) BETWEEN 1 AND 120),
  pricing_version text NOT NULL CHECK (length(pricing_version) BETWEEN 1 AND 120),
  pricing jsonb NOT NULL CHECK (jsonb_typeof(pricing) = 'object'),
  opening_micros bigint NOT NULL CHECK (opening_micros >= 0),
  limit_micros bigint NOT NULL CHECK (limit_micros > 0 AND limit_micros <= 45000000000),
  baseline_verified_at timestamptz NOT NULL,
  enabled boolean NOT NULL DEFAULT false
);

CREATE TABLE payse.analysis_cost_calls (
  id uuid PRIMARY KEY,
  project_id text NOT NULL REFERENCES payse.analysis_cost_projects(project_id),
  pricing_version text NOT NULL,
  category text NOT NULL CHECK (category IN ('model', 'counting', 'kms')),
  maximum_micros bigint NOT NULL CHECK (maximum_micros >= 0),
  actual_micros bigint CHECK (actual_micros >= 0),
  state text NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved', 'settled', 'released')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  dispatched_at timestamptz,
  finished_at timestamptz,
  CHECK (
    (state = 'reserved' AND actual_micros IS NULL AND finished_at IS NULL)
    OR (state = 'settled' AND actual_micros IS NOT NULL AND finished_at IS NOT NULL)
    OR (state = 'released' AND actual_micros = 0 AND finished_at IS NOT NULL)
  )
);
CREATE INDEX analysis_cost_calls_project ON payse.analysis_cost_calls(project_id);

REVOKE ALL ON payse.analysis_cost_projects, payse.analysis_cost_calls FROM PUBLIC, payse_runtime;

-- 2026-11-03: AnalysisCosts.policy가 승인 단가만 읽는다. 원문 자격을 저장하지 않는다.
CREATE FUNCTION payse.analysis_cost_policy(requested_project text, requested_version text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
  SELECT pricing
  FROM payse.analysis_cost_projects
  WHERE project_id = requested_project
    AND pricing_version = requested_version
    AND enabled
$$;

-- 2026-11-03: AnalysisCosts.reserve가 같은 프로젝트의 예약·정산 비용을 한 잠금 아래 합산한다.
CREATE FUNCTION payse.analysis_cost_reserve(
  requested_project text,
  call_id uuid,
  requested_version text,
  requested_category text,
  maximum bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  policy payse.analysis_cost_projects%ROWTYPE;
  previous payse.analysis_cost_calls%ROWTYPE;
  total numeric;
BEGIN
  IF call_id IS NULL
    OR maximum IS NULL
    OR maximum < 0
    OR requested_category IS NULL
    OR requested_category NOT IN ('model', 'counting', 'kms') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Invalid cost reservation';
  END IF;
  SELECT *
  INTO policy
  FROM payse.analysis_cost_projects
  WHERE project_id = requested_project
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P4500', MESSAGE = 'Cost policy unavailable';
  END IF;
  SELECT *
  INTO previous
  FROM payse.analysis_cost_calls
  WHERE id = call_id;
  IF FOUND THEN
    -- 호출 식별 재사용은 외부 재전송 허가가 아니다. 이미 끝난 예약도 되살리지 않는다.
    IF previous.project_id IS DISTINCT FROM requested_project
      OR previous.pricing_version IS DISTINCT FROM requested_version
      OR previous.category IS DISTINCT FROM requested_category
      OR previous.maximum_micros IS DISTINCT FROM maximum THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Cost reservation conflict';
    END IF;
    RETURN;
  END IF;
  IF NOT policy.enabled
    OR policy.pricing_version IS DISTINCT FROM requested_version THEN
    RAISE EXCEPTION USING ERRCODE = 'P4500', MESSAGE = 'Cost policy unavailable';
  END IF;
  SELECT policy.opening_micros + coalesce(sum(
    CASE WHEN state = 'reserved' THEN maximum_micros ELSE actual_micros END
  ), 0)
  INTO total
  FROM payse.analysis_cost_calls
  WHERE project_id = requested_project;
  IF total >= policy.limit_micros
    OR total + maximum >= policy.limit_micros THEN
    RAISE EXCEPTION USING ERRCODE = 'P4501', MESSAGE = 'Cost limit reached';
  END IF;
  INSERT INTO payse.analysis_cost_calls (
    id,
    project_id,
    pricing_version,
    category,
    maximum_micros
  ) VALUES (
    call_id,
    requested_project,
    requested_version,
    requested_category,
    maximum
  );
END
$$;

-- 2026-11-03: AnalysisCosts.start가 전송 직전에 단 한 번의 실행권을 확정한다.
CREATE FUNCTION payse.analysis_cost_start(requested_project text, call_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  policy payse.analysis_cost_projects%ROWTYPE;
  total numeric;
  changed integer;
BEGIN
  SELECT *
  INTO policy
  FROM payse.analysis_cost_projects
  WHERE project_id = requested_project
  FOR UPDATE;
  IF NOT FOUND OR NOT policy.enabled THEN
    RETURN false;
  END IF;

  SELECT policy.opening_micros + coalesce(sum(
    CASE WHEN state = 'reserved' THEN maximum_micros ELSE actual_micros END
  ), 0)
  INTO total
  FROM payse.analysis_cost_calls
  WHERE project_id = requested_project;
  IF total >= policy.limit_micros THEN
    RETURN false;
  END IF;

  UPDATE payse.analysis_cost_calls
  SET dispatched_at = clock_timestamp()
  WHERE id = call_id
    AND project_id = requested_project
    AND pricing_version = policy.pricing_version
    AND state = 'reserved'
    AND dispatched_at IS NULL;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END
$$;

-- 2026-11-03: AnalysisCosts.releaseUnstarted는 전송권을 얻지 않은 예약만 반납한다.
CREATE FUNCTION payse.analysis_cost_release(requested_project text, call_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  PERFORM project_id
  FROM payse.analysis_cost_projects
  WHERE project_id = requested_project
  FOR UPDATE;

  UPDATE payse.analysis_cost_calls
  SET state = 'released',
    actual_micros = 0,
    finished_at = clock_timestamp()
  WHERE id = call_id
    AND project_id = requested_project
    AND state = 'reserved'
    AND dispatched_at IS NULL;
END
$$;

-- 2026-11-03: AnalysisCosts.finish가 관측 사용액을 결과 저장·세션 상태와 관계없이 보존한다.
CREATE FUNCTION payse.analysis_cost_finish(
  requested_project text,
  call_id uuid,
  actual bigint,
  not_sent boolean
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  previous payse.analysis_cost_calls%ROWTYPE;
BEGIN
  IF actual IS NULL
    OR actual < 0
    OR not_sent IS NULL
    OR (not_sent AND actual <> 0) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Invalid cost settlement';
  END IF;
  -- 예약과 같은 잠금 순서를 사용하여 정산·신규 예약의 경합을 직렬화한다.
  PERFORM project_id
  FROM payse.analysis_cost_projects
  WHERE project_id = requested_project
  FOR UPDATE;
  SELECT *
  INTO previous
  FROM payse.analysis_cost_calls
  WHERE id = call_id
    AND project_id = requested_project
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Cost reservation missing';
  END IF;
  IF previous.state <> 'reserved' THEN
    IF previous.actual_micros IS DISTINCT FROM actual
      OR (previous.state = 'released') IS DISTINCT FROM not_sent THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Cost settlement conflict';
    END IF;
    RETURN;
  END IF;
  -- 실제 사용액이 예약을 초과해도 회계 사실을 버리지 않는다. 후속 예약은 새 합계로 차단된다.
  UPDATE payse.analysis_cost_calls
  SET actual_micros = actual,
    state = CASE WHEN not_sent THEN 'released' ELSE 'settled' END,
    finished_at = clock_timestamp()
  WHERE id = call_id;
END
$$;

REVOKE ALL ON FUNCTION payse.analysis_cost_policy(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION payse.analysis_cost_reserve(text, uuid, text, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION payse.analysis_cost_finish(text, uuid, bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION payse.analysis_cost_start(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION payse.analysis_cost_release(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION payse.analysis_cost_policy(text, text) TO payse_runtime;
GRANT EXECUTE ON FUNCTION payse.analysis_cost_reserve(text, uuid, text, text, bigint) TO payse_runtime;
GRANT EXECUTE ON FUNCTION payse.analysis_cost_finish(text, uuid, bigint, boolean) TO payse_runtime;
GRANT EXECUTE ON FUNCTION payse.analysis_cost_start(text, uuid) TO payse_runtime;
GRANT EXECUTE ON FUNCTION payse.analysis_cost_release(text, uuid) TO payse_runtime;
