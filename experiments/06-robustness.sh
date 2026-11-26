#!/usr/bin/env bash
# 실험 6. 예외 상황 및 방어 동작 — 잘못된 입력/충돌/연속 변경에서 시스템이 어떻게 버티는가
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }

section "실험 6. 예외 상황 및 방어 동작"
echo "관점: 잘못된 요청이 DNS 서비스 자체를 망가뜨리지 않고 거부되는가,"
echo "      그리고 거부된 뒤에도 시스템이 계속 정상 동작하는가."

step "6-1. A 레코드에 IP 가 아닌 값 수정 시도 (PUT)"
rid=$(record_id_by_value "$NODE1_IP")
echo "대상 record id = $rid (api.lab.test -> $NODE1_IP)"
echo -n "PUT value='not an ip!!' -> HTTP "
code -X PUT "$BACKEND/records/$rid" -H "Content-Type: application/json" -d '{"value":"not an ip!!","ttl":30}'
echo " (422 = 거부)"
echo "응답: $(body -X PUT "$BACKEND/records/$rid" -H 'Content-Type: application/json' -d '{"value":"not an ip!!","ttl":30}')"
echo
echo "거부 후에도 DNS 가 정상인지: $(dig_q api.lab.test A +short | tr '\n' ' ')"

step "6-2. TTL 범위 밖 값"
for t in 0 -5 999999999; do
  echo -n "  ttl=$t -> HTTP "
  code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
    -d "{\"domain\":\"ttlbad.lab.test\",\"record_type\":\"A\",\"value\":\"10.1.1.1\",\"ttl\":$t}"
  echo
done

step "6-3. CNAME 공존 규칙 (RFC 1034) — 생성 경로"
echo -n "  cnflict.lab.test A 생성 -> HTTP "
code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
  -d '{"domain":"cnflict.lab.test","record_type":"A","value":"10.4.4.4","ttl":30}'; echo
echo -n "  같은 이름에 CNAME 생성 -> HTTP "
code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
  -d '{"domain":"cnflict.lab.test","record_type":"CNAME","value":"api.lab.test","ttl":30}'; echo " (409 = 거부)"

step "6-4. CNAME 공존 규칙 — 비활성 레코드를 되살리는 경로"
echo "비활성 레코드를 다시 켜는 순간에도 충돌이 생길 수 있으므로 같은 검사를 한다."
cid=$(record_id_by_value "10.4.4.4")
echo -n "  A(id=$cid) 비활성화 -> HTTP "
code -X PATCH "$BACKEND/records/$cid" -H "Content-Type: application/json" -d '{"enabled":false}'; echo
echo -n "  이제 CNAME 생성 (A 가 꺼져 있으므로 허용) -> HTTP "
code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
  -d '{"domain":"cnflict.lab.test","record_type":"CNAME","value":"api.lab.test","ttl":30}'; echo
echo -n "  A 를 다시 활성화 -> HTTP "
code -X PATCH "$BACKEND/records/$cid" -H "Content-Type: application/json" -d '{"enabled":true}'; echo " (409 = 거부)"
echo "  응답: $(body -X PATCH "$BACKEND/records/$cid" -H 'Content-Type: application/json' -d '{"enabled":true}')"
echo
echo "  거부 후 DB 상태 (A 는 비활성으로 유지되어야 함):"
body "$BACKEND/records" | tr '}' '\n' | grep cnflict | sed 's/^/    /'
echo -n "  거부 후에도 무관한 레코드를 추가할 수 있는가 -> HTTP "
code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
  -d '{"domain":"stillworks.lab.test","record_type":"A","value":"10.5.5.5","ttl":30}'
echo " (201 = 시스템이 멈추지 않음)"

step "6-5. 같은 1초 안에 연속 변경 (SOA serial 단조 증가 확인)"
echo "CoreDNS 는 SOA serial 이 직전과 같으면 내용이 달라도 존을 다시 읽지 않는다."
echo "따라서 초 단위 serial 을 그대로 쓰면 같은 초의 두 번째 변경이 유실된다."
echo "변경 직후 serial:"
for n in 1 2 3; do
  curl -s -o /dev/null -X POST "$BACKEND/records" -H "Content-Type: application/json" \
    -d "{\"domain\":\"burst$n.lab.test\",\"record_type\":\"A\",\"value\":\"10.6.6.$n\",\"ttl\":30}"
  echo "  [$n] $($COMPOSE exec -T backend sh -c 'grep serial /zone/db.lab.test' | tr -d ' ')"
done
echo "DNS 반영 대기 (4초)..."
sleep 4
echo "세 건 모두 DNS 에 반영되었는가:"
for n in 1 2 3; do
  echo "  burst$n.lab.test -> $(dig_q burst$n.lab.test A +short | tr '\n' ' ')"
done

step "6-6. 멱등성 — 같은 요청을 반복해도 상태가 누적되지 않는가"
echo -n "  동일 레코드 POST 4회 -> HTTP "
for i in 1 2 3 4; do
  code -X POST "$BACKEND/records" -H "Content-Type: application/json" \
    -d '{"domain":"idem.lab.test","record_type":"A","value":"10.7.7.7","ttl":30}'
  echo -n " "
done
echo "(첫 201, 이후 200)"
echo "  실제 저장 건수: $(body "$BACKEND/records" | tr '}' '\n' | grep -c '"domain":"idem.lab.test"')"
iid=$(record_id_by_value "10.7.7.7")
# 감사 로그는 누적 보존되고 SQLite 는 삭제된 id 를 재사용하므로,
# 도메인이나 record_id 로 세면 과거 실행분이 섞인다.
# 호출 전후의 증가분으로 재야 '이번 3회 요청이 몇 건을 남겼는가' 가 분리된다.
audit_disable_count() { body "$BACKEND/audit-logs" | tr '}' '\n' | grep -c '"action":"disable"'; }
before=$(audit_disable_count)
echo -n "  PATCH disable 3회 -> HTTP "
for i in 1 2 3; do code -X PATCH "$BACKEND/records/$iid" -H "Content-Type: application/json" -d '{"enabled":false}'; echo -n " "; done; echo
after=$(audit_disable_count)
echo "  disable 감사 로그 증가분: $((after - before)) 건 (PATCH 3회 -> 1건이어야 정상)"
echo -n "  DELETE 3회 -> HTTP "
for i in 1 2 3; do code -X DELETE "$BACKEND/records/$iid"; echo -n " "; done; echo "(204 = 멱등)"

step "6-7. 질의 테스트에 잘못된 도메인 입력"
for d in '..' 'a..b' 'very-long-label-that-is-way-over-sixty-three-characters-limit-aaaaaaaaaa.lab.test'; do
  echo -n "  [${d:0:40}] -> HTTP "
  code -X POST "$BACKEND/query-test" -H "Content-Type: application/json" -d "{\"domain\":\"$d\",\"record_type\":\"A\"}"
  echo
done

step "6-8. forwarding 설정에 잘못된 값"
for u in '["not-an-ip"]' '["8.8.8.8; rm -rf /"]' '[]' '["8.8.8.8","8.8.8.8"]'; do
  echo -n "  $u -> HTTP "
  code -X PUT "$BACKEND/forwarding" -H "Content-Type: application/json" -d "{\"upstreams\":$u}"
  echo
done
echo "  현재 설정이 보존되었는가: $(body "$BACKEND/forwarding")"

step "6-9. 정리 및 최종 상태 확인"
for d in cnflict stillworks burst1 burst2 burst3; do
  for id in $(body "$BACKEND/records" | tr '}' '\n' | grep "\"domain\":\"$d.lab.test\"" | grep -o '"id":[0-9]*' | cut -d: -f2); do
    curl -s -o /dev/null -X DELETE "$BACKEND/records/$id"
  done
done
sleep 3
echo "남은 레코드 (00-setup.sh 가 구성한 baseline 6건 — 실험이 만든 레코드는 모두 정리됨):"
body "$BACKEND/records" | tr '}' '\n' | grep -o '"domain":"[^"]*","record_type":"[^"]*","value":"[^"]*"' | sed 's/^/    /'
echo "api.lab.test 최종 응답: $(dig_q api.lab.test A +short | tr '\n' ' ')"
echo "CoreDNS 존 파싱 에러 건수: $($COMPOSE logs coredns --since 5m 2>&1 | grep -c 'plugin/file: Parsing zone')"
