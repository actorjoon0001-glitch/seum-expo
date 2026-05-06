-- 세움 박람회 QR 이벤트 스키마 (간소판)
-- 휴대폰 번호 기준 중복 방지 + "사은품 수령하기" 단일 버튼 흐름
--
-- 적용:  Supabase 프로젝트 SQL Editor 에 통째로 붙여넣기 → Run
-- 사용:  index.html 의 anon key 만 사용. 별도 직원 로그인 없음.

-- ============================================================
-- 참여자
-- ============================================================
create table if not exists participants (
  id                bigserial primary key,
  created_at        timestamptz not null default now(),

  name              text not null,
  phone             text not null,                -- 사용자가 입력한 원문
  phone_normalized  text not null,                -- 숫자만 (010-1234-5678 → 01012345678)

  product           text,
  period            text,
  land              text,
  memo              text,
  grade             text,

  gift_status       text not null default 'pending'
                      check (gift_status in ('pending','completed')),
  gift_received_at  timestamptz,

  -- 새로고침/재시도 시 동일 결과 반환용 클라이언트 토큰
  client_token      text unique
);

-- 동일 정규화 번호는 1건만 허용 → 중복 등록 차단
create unique index if not exists participants_phone_norm_uniq
  on participants (phone_normalized);

create index if not exists participants_status_idx  on participants (gift_status);
create index if not exists participants_created_idx on participants (created_at desc);


-- ============================================================
-- 등록 RPC (anon 호출)
--   결과:
--     ok=true                              → 신규 등록 성공
--     ok=false, reason='ALREADY_RECEIVED'  → 동일 번호가 이미 지급완료
--     ok=false, reason='ALREADY_REGISTERED'→ 동일 번호가 이미 등록됨(지급대기)
--     ok=false, reason='INVALID_PHONE'     → 번호 형식 오류
--     ok=true, replayed=true               → 동일 토큰 재요청 (새로고침 등)
-- ============================================================
create or replace function register_participant(
  p_name         text,
  p_phone        text,
  p_product      text,
  p_period       text,
  p_land         text,
  p_memo         text,
  p_grade        text,
  p_client_token text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_norm text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_row  participants%rowtype;
  v_id   bigint;
begin
  if length(v_norm) < 10 or length(v_norm) > 11 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_PHONE');
  end if;

  -- 새로고침/네트워크 재시도 → 같은 토큰이면 기존 결과 그대로 반환
  if p_client_token is not null then
    select * into v_row from participants where client_token = p_client_token;
    if found then
      return jsonb_build_object(
        'ok', true, 'replayed', true,
        'participant_id', v_row.id,
        'gift_status', v_row.gift_status,
        'phone_normalized', v_row.phone_normalized
      );
    end if;
  end if;

  -- 동일 번호 기존 등록 확인
  select * into v_row from participants where phone_normalized = v_norm;
  if found then
    if v_row.gift_status = 'completed' then
      return jsonb_build_object(
        'ok', false, 'reason', 'ALREADY_RECEIVED',
        'participant_id', v_row.id,
        'phone_normalized', v_norm
      );
    else
      return jsonb_build_object(
        'ok', false, 'reason', 'ALREADY_REGISTERED',
        'participant_id', v_row.id,
        'phone_normalized', v_norm
      );
    end if;
  end if;

  insert into participants
    (name, phone, phone_normalized, product, period, land, memo, grade, client_token)
  values
    (p_name, p_phone, v_norm, p_product, p_period, p_land, p_memo, p_grade, p_client_token)
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'participant_id', v_id,
    'gift_status', 'pending',
    'phone_normalized', v_norm
  );
end $$;

grant execute on function register_participant(text,text,text,text,text,text,text,text) to anon, authenticated;


-- ============================================================
-- 사은품 수령 처리 RPC
--   - 이미 completed 면 그대로 성공 반환 (멱등) → 버튼 연타/새로고침 안전
--   - participant_id + client_token 둘 다 검증해서 다른 사용자 화면에서
--     임의로 처리하는 것을 어렵게 함
-- ============================================================
create or replace function mark_gift_received(
  p_participant_id bigint,
  p_client_token   text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row participants%rowtype;
begin
  select * into v_row from participants
   where id = p_participant_id and client_token = p_client_token
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
  end if;

  if v_row.gift_status = 'completed' then
    return jsonb_build_object(
      'ok', true, 'gift_status', 'completed',
      'gift_received_at', v_row.gift_received_at, 'already', true
    );
  end if;

  update participants
     set gift_status = 'completed',
         gift_received_at = now()
   where id = p_participant_id
   returning gift_received_at into v_row.gift_received_at;

  return jsonb_build_object(
    'ok', true, 'gift_status', 'completed',
    'gift_received_at', v_row.gift_received_at
  );
end $$;

grant execute on function mark_gift_received(bigint, text) to anon, authenticated;


-- ============================================================
-- RLS  (RPC 만 사용하므로 직접 select/insert 는 차단)
-- ============================================================
alter table participants enable row level security;
-- 정책을 추가하지 않으면 anon 의 직접 접근은 모두 거부되며,
-- security definer 함수(RPC)만 통과한다.
