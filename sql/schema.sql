-- ============================================================================
--  在线限时答题系统 · 数据库结构（PostgreSQL）
-- ----------------------------------------------------------------------------
--  设计要点
--    * 所有表都开启 RLS，且不创建任何策略 → 匿名角色（anon）无法直接读写，
--      只能通过下面这些 SECURITY DEFINER 函数访问。
--    * 考生侧函数不需要口令；评卷侧函数都要求传入 token。
--    * 部署前请把下面的 CHANGE_ME_ADMIN_TOKEN 改成你自己的强口令，
--      并同步修改 admin.html / index.html 中调用时传入的值。
-- ============================================================================


-- ============================ 1. 表结构 ====================================

CREATE TABLE IF NOT EXISTS exam_submissions (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id    TEXT        NOT NULL UNIQUE,          -- 前端生成的一次答题会话号
  student_name  TEXT        NOT NULL,
  student_class TEXT        NOT NULL,
  started_at    TIMESTAMPTZ NOT NULL,                 -- 开考时刻（服务端为准）
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  submitted_at  TIMESTAMPTZ,                          -- 交卷时刻，NULL = 未交卷
  elapsed_sec   INTEGER,                              -- 用时（秒）
  submit_type   TEXT,                                 -- manual | timeout
  answers       JSONB       NOT NULL DEFAULT '{}'::jsonb,
  scores        JSONB,                                -- 逐题得分
  total_score   NUMERIC,
  reviewer      TEXT,
  reviewed_at   TIMESTAMPTZ,
  released_at   TIMESTAMPTZ,                          -- 非空 = 该身份已被重置，可再次选择
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 键值配置表：目前只用来存入场时间窗
CREATE TABLE IF NOT EXISTS exam_settings (
  key        TEXT PRIMARY KEY,
  value      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE exam_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE exam_settings    ENABLE ROW LEVEL SECURITY;

-- 同一身份「同时」只能有一条有效记录 → 每个身份只能作答一次。
-- 重置（写入 released_at）后该身份被释放，可以重新答题，旧记录保留。
CREATE UNIQUE INDEX IF NOT EXISTS exam_active_identity_uniq
  ON exam_submissions (student_name, student_class)
  WHERE released_at IS NULL;


-- ============================ 2. 公共只读函数 ==============================

-- 以服务端时间为准返回当前时刻，前端用它建立计时基准
CREATE OR REPLACE FUNCTION exam_now()
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT now()
$$;

-- 查询某次会话的状态
CREATE OR REPLACE FUNCTION exam_status(p_session_id text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT COALESCE((
    SELECT jsonb_build_object(
      'found',       true,
      'submitted',   s.submitted_at IS NOT NULL,
      'submit_type', s.submit_type,
      'elapsed_sec', s.elapsed_sec,
      'started_at',  s.started_at,
      'released',    s.released_at IS NOT NULL,
      'released_at', s.released_at,
      'updated_at',  s.updated_at
    ) FROM exam_submissions s WHERE s.session_id = p_session_id
  ), '{"found": false}'::jsonb)
$$;

-- 已被占用的身份列表（用于把名单里已选过的名字置灰）
CREATE OR REPLACE FUNCTION exam_taken()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('c', student_class, 'n', student_name)), '[]'::jsonb)
  FROM exam_submissions WHERE released_at IS NULL
$$;

-- 入场时间窗状态。state: unset | before | open | closed
CREATE OR REPLACE FUNCTION exam_entrance()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb; o timestamptz; c timestamptz; st text;
BEGIN
  SELECT value INTO v FROM exam_settings WHERE key = 'entrance';
  IF v IS NULL THEN
    RETURN jsonb_build_object('set', false, 'open_at', NULL, 'close_at', NULL, 'now', now(), 'state', 'unset');
  END IF;
  o := NULLIF(v->>'open_at',  '')::timestamptz;
  c := NULLIF(v->>'close_at', '')::timestamptz;
  IF o IS NULL AND c IS NULL THEN
    RETURN jsonb_build_object('set', false, 'open_at', NULL, 'close_at', NULL, 'now', now(), 'state', 'unset');
  END IF;
  IF    o IS NOT NULL AND now() < o THEN st := 'before';
  ELSIF c IS NOT NULL AND now() > c THEN st := 'closed';
  ELSE  st := 'open';
  END IF;
  RETURN jsonb_build_object('set', true, 'open_at', o, 'close_at', c, 'now', now(), 'state', st);
END $$;


-- ============================ 3. 考生侧写入函数 ============================

-- 开考 / 暂存 / 交卷 三合一。
--   * 会话不存在 → 建会话（此时校验入场时间与身份唯一性）
--   * 会话已存在 → 更新答案；若已交卷则不再改动（一次交卷不可改）
-- 可能抛出的错误码：
--   IDENTITY_TAKEN      该身份已经被使用过
--   ENTRANCE_NOT_OPEN   尚未开放入场
--   ENTRANCE_CLOSED     入场时间已截止
CREATE OR REPLACE FUNCTION exam_save(
  p_session_id text,
  p_name       text,
  p_class      text,
  p_started_at timestamptz,
  p_answers    jsonb,
  p_submit_type text    DEFAULT NULL,
  p_elapsed     integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_new boolean; v_cfg jsonb; v_open timestamptz; v_close timestamptz;
BEGIN
  IF p_session_id IS NULL OR length(p_session_id) < 8 THEN
    RAISE EXCEPTION 'invalid session id';
  END IF;
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'missing name';
  END IF;

  SELECT NOT EXISTS (SELECT 1 FROM exam_submissions WHERE session_id = p_session_id) INTO v_new;

  IF v_new THEN
    -- 入场时间窗校验（只拦新进入考场的人，已开考的选手不受截止影响）
    SELECT value INTO v_cfg FROM exam_settings WHERE key = 'entrance';
    IF v_cfg IS NOT NULL THEN
      v_open  := NULLIF(v_cfg->>'open_at',  '')::timestamptz;
      v_close := NULLIF(v_cfg->>'close_at', '')::timestamptz;
      IF v_open  IS NOT NULL AND now() < v_open THEN RAISE EXCEPTION 'ENTRANCE_NOT_OPEN'; END IF;
      IF v_close IS NOT NULL AND now() > v_close THEN RAISE EXCEPTION 'ENTRANCE_CLOSED';  END IF;
    END IF;

    -- 身份唯一性校验（并发时由唯一索引兜底）
    IF EXISTS (
      SELECT 1 FROM exam_submissions
      WHERE student_name = p_name AND student_class = COALESCE(p_class, '')
        AND released_at IS NULL
    ) THEN
      RAISE EXCEPTION 'IDENTITY_TAKEN';
    END IF;

    BEGIN
      INSERT INTO exam_submissions
        (session_id, student_name, student_class, started_at, answers, submit_type, submitted_at, elapsed_sec)
      VALUES (
        p_session_id, p_name, COALESCE(p_class, ''), COALESCE(p_started_at, now()),
        COALESCE(p_answers, '{}'::jsonb), p_submit_type,
        CASE WHEN p_submit_type IS NOT NULL THEN now() ELSE NULL END,
        p_elapsed
      );
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'IDENTITY_TAKEN';
    END;
  ELSE
    UPDATE exam_submissions SET
      answers      = COALESCE(p_answers, '{}'::jsonb),
      updated_at   = now(),
      submit_type  = COALESCE(exam_submissions.submit_type, p_submit_type),
      submitted_at = COALESCE(exam_submissions.submitted_at,
                              CASE WHEN p_submit_type IS NOT NULL THEN now() ELSE NULL END),
      elapsed_sec  = COALESCE(exam_submissions.elapsed_sec, p_elapsed)
    WHERE session_id = p_session_id AND submitted_at IS NULL;
  END IF;

  RETURN jsonb_build_object('ok', true, 'claimed', v_new);
END $$;


-- ============================ 4. 管理端函数 ================================
-- 一律要求 token 匹配，否则抛 'unauthorized'

-- 拉取全部答卷
CREATE OR REPLACE FUNCTION admin_list(p_token text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at), '[]'::jsonb) INTO v
  FROM (
    SELECT id, session_id, student_name, student_class, started_at, submitted_at,
           elapsed_sec, submit_type, released_at, answers, scores, total_score,
           reviewer, reviewed_at, created_at
    FROM exam_submissions
  ) t;
  RETURN v;
END $$;

-- 保存某份答卷的评分
CREATE OR REPLACE FUNCTION admin_save_score(
  p_token text, p_id bigint, p_scores jsonb, p_total numeric, p_reviewer text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  UPDATE exam_submissions
     SET scores = p_scores, total_score = p_total, reviewer = p_reviewer, reviewed_at = now()
   WHERE id = p_id;
END $$;

-- 重置单个身份：写入 released_at，该身份可再次被选择，答卷记录保留
CREATE OR REPLACE FUNCTION admin_reset(p_token text, p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_name text;
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  UPDATE exam_submissions
     SET released_at = now(), updated_at = now()
   WHERE id = p_id AND released_at IS NULL
  RETURNING student_name INTO v_name;
  RETURN jsonb_build_object('ok', true, 'name', v_name);
END $$;

-- 一次性释放全部身份（测试用）
CREATE OR REPLACE FUNCTION admin_reset_all(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n integer;
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  UPDATE exam_submissions SET released_at = now(), updated_at = now() WHERE released_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'released', n);
END $$;

-- 删除一条记录
CREATE OR REPLACE FUNCTION admin_delete(p_token text, p_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  DELETE FROM exam_submissions WHERE id = p_id;
END $$;

-- 设置入场时间窗；两项都传 NULL 表示清除（不限入场时间）
CREATE OR REPLACE FUNCTION admin_set_entrance(
  p_token text, p_open timestamptz, p_close timestamptz
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_token IS DISTINCT FROM 'CHANGE_ME_ADMIN_TOKEN' THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF p_open IS NOT NULL AND p_close IS NOT NULL AND p_open >= p_close THEN
    RAISE EXCEPTION 'BAD_RANGE';
  END IF;
  IF p_open IS NULL AND p_close IS NULL THEN
    DELETE FROM exam_settings WHERE key = 'entrance';
  ELSE
    INSERT INTO exam_settings (key, value, updated_at)
    VALUES ('entrance', jsonb_build_object('open_at', p_open, 'close_at', p_close), now())
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  END IF;
  RETURN exam_entrance();
END $$;


-- ============================ 5. 收尾 ======================================
-- 新建函数后刷新 PostgREST 的 schema 缓存（自建 PostgREST 时很关键）
NOTIFY pgrst, 'reload schema';
