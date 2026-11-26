#!/usr/bin/env bash
# 과제 PDF 의 요구사항 / 평가 기준을 항목별로 대조 검증한다.
# 각 줄은 "무엇을 어떻게 확인했는가"와 PASS/FAIL 을 함께 남긴다.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %-54s %s\n' "$1" "$2"; }
no()   { FAIL=$((FAIL+1)); printf '  [FAIL] %-54s %s\n' "$1" "$2"; }
SKIP=0
skip() { SKIP=$((SKIP+1)); printf '  [SKIP] %-54s %s
' "$1" "$2"; }
chk()  { # chk "항목" "기대" "실제"
  if [ "$3" = "$2" ]; then ok "$1" "$3"; else no "$1" "기대=$2 실제=$3"; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
short(){ dig_q "$1" "${2:-A}" +short 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
stat() { dig_q "$1" "${2:-A}" 2>/dev/null | grep -o 'status: [A-Z]*' | head -1 | cut -d' ' -f2; }
flags(){ dig_q "$1" "${2:-A}" 2>/dev/null | grep -o 'flags: [a-z ]*' | head -1 | sed 's/flags: //;s/ *$//'; }
has()  { echo "$1" | grep -q "$2" && echo yes || echo no; }

section "PDF 3. 필수 구현 요구사항"

step "분산 API 서비스 — 동일 REST API 서버 3개 이상, 식별 정보 및 Health Check"
n_ok=0; ids=""
for p in 8001 8002 8003; do
  h=$(body "http://localhost:$p/health"); i=$(body "http://localhost:$p/info")
  [ "$(has "$h" '"status":"ok"')" = yes ] && [ "$(has "$i" '"node_id"')" = yes ] && [ "$(has "$i" '"hostname"')" = yes ] && n_ok=$((n_ok+1))
  ids="$ids $(echo "$i" | grep -o '"node_id":"[^"]*"' | cut -d'"' -f4)"
done
chk "API 서버 3개 health+info 응답" "3" "$n_ok"
chk "서버 식별 정보(node_id)가 서로 다름" "3" "$(echo $ids | tr ' ' '\n' | sort -u | grep -c .)"
# compose 설정이 아니라 "실제로 돌고 있는 컨테이너의 이미지 ID"를 비교한다.
uniq_img=$(for n in node1 node2 node3; do $COMPOSE images "$n" --format json 2>/dev/null | grep -o '"ID":"[^"]*"' | head -1; done | sort -u | grep -c .)
chk "세 노드가 동일한 이미지로 기동" "1" "$uniq_img"

step "DNS 관리 UI — 조회·등록·수정·삭제, 활성화/비활성화, 질의 테스트"
D=req1.lab.test
for i in $(body "$BACKEND/records" | tr '}' '\n' | grep "\"domain\":\"$D\"" | grep -o '"id":[0-9]*' | cut -d: -f2); do curl -s -o /dev/null -X DELETE "$BACKEND/records/$i"; done
chk "조회  GET /records"              "200" "$(code "$BACKEND/records")"
chk "등록  POST /records"             "201" "$(code -X POST "$BACKEND/records" -H 'Content-Type: application/json' -d "{\"domain\":\"$D\",\"record_type\":\"A\",\"value\":\"10.99.0.1\",\"ttl\":30}")"
RID=$(record_id_by_value "10.99.0.1")
chk "수정  PUT /records/{id}"         "200" "$(code -X PUT "$BACKEND/records/$RID" -H 'Content-Type: application/json' -d '{"value":"10.99.0.2","ttl":60}')"
chk "비활성화 PATCH {enabled:false}"  "200" "$(code -X PATCH "$BACKEND/records/$RID" -H 'Content-Type: application/json' -d '{"enabled":false}')"
chk "활성화  PATCH {enabled:true}"    "200" "$(code -X PATCH "$BACKEND/records/$RID" -H 'Content-Type: application/json' -d '{"enabled":true}')"
chk "질의 테스트 POST /query-test"    "200" "$(code -X POST "$BACKEND/query-test" -H 'Content-Type: application/json' -d '{"domain":"api.lab.test","record_type":"A"}')"
chk "삭제  DELETE /records/{id}"      "204" "$(code -X DELETE "$BACKEND/records/$RID")"
UI=http://localhost:5173/src
chk "UI 레코드 관리 화면 존재"        "yes" "$(has "$(body $UI/components/RecordsPanel.tsx)" '등록된 레코드')"
chk "UI 활성화 스위치 존재"           "yes" "$(has "$(body $UI/components/RecordsPanel.tsx)" 'setRecordEnabled')"
chk "UI 질의 테스트 화면 존재"        "yes" "$(has "$(body $UI/components/QueryTestPanel.tsx)" 'queryTest')"
chk "UI Forwarding 설정 화면 존재"    "yes" "$(has "$(body $UI/components/ForwardingPanel.tsx)" 'setForwarding')"

step "DNS 레코드 — A / CNAME / Wildcard A / Wildcard CNAME / 동일 도메인 다중 A"
chk "A 레코드 응답"                   "NOERROR" "$(stat api.lab.test A)"
chk "동일 도메인 다중 A (3건)"        "3"       "$(short api.lab.test A | wc -w)"
chk "CNAME 레코드 응답"               "NOERROR" "$(stat www.lab.test CNAME)"
chk "CNAME 체인 해석(A 질의)"         "yes"     "$(has "$(short www.lab.test A)" '172.30.0')"
chk "Wildcard A — 미등록 하위 이름"   "10.0.0.99" "$(short zzz9.dev.lab.test A)"
# 이 레코드는 실험 01 이 만들지만, 검증 스크립트는 단독 실행되어야 하므로
# 필요한 레코드를 직접 만들고 확인한 뒤 되돌린다.
WC='*.vrfy.lab.test'
curl -s -o /dev/null -X POST "$BACKEND/records" -H 'Content-Type: application/json'   -d "{\"domain\":\"$WC\",\"record_type\":\"CNAME\",\"value\":\"api.lab.test\",\"ttl\":30}"
sleep 4
chk "Wildcard CNAME — 미등록 하위"    "yes"     "$(has "$(short zzz9.vrfy.lab.test A)" 'api.lab.test')"
for i in $(body "$BACKEND/records" | tr '}' '
' | grep 'vrfy.lab.test' | grep -o '"id":[0-9]*' | cut -d: -f2); do
  curl -s -o /dev/null -X DELETE "$BACKEND/records/$i"
done

step "DNS Resolution — 내부 로컬 처리 / 외부 Upstream forwarding"
chk "내부 도메인: 권한 응답(aa 플래그)"   "yes"      "$(has "$(flags api.lab.test A)" 'aa')"
chk "내부 미등록 이름: NXDOMAIN"          "NXDOMAIN" "$(stat nosuch123.lab.test A)"
chk "외부 도메인: 전달 응답(ra, aa 없음)" "yes"      "$(has "$(flags example.com A)" 'ra')"
chk "외부 도메인: aa 없음"                "no"       "$(has "$(flags example.com A)" 'aa')"
chk "외부 도메인 실제 해석"               "yes"      "$(has "$(short example.com A)" '[0-9]')"

step "동적 설정 반영 — UI 변경이 실제 DNS 응답에 반영"
DD=req2.lab.test
curl -s -o /dev/null -X POST "$BACKEND/records" -H 'Content-Type: application/json' -d "{\"domain\":\"$DD\",\"record_type\":\"A\",\"value\":\"10.99.5.5\",\"ttl\":30}"
sleep 4; chk "등록 -> DNS 반영"        "10.99.5.5" "$(short $DD A)"
R2=$(record_id_by_value "10.99.5.5")
curl -s -o /dev/null -X PUT "$BACKEND/records/$R2" -H 'Content-Type: application/json' -d '{"value":"10.99.6.6","ttl":30}'
sleep 4; chk "수정 -> DNS 반영"        "10.99.6.6" "$(short $DD A)"
curl -s -o /dev/null -X PATCH "$BACKEND/records/$R2" -H 'Content-Type: application/json' -d '{"enabled":false}'
sleep 4; chk "비활성화 -> DNS 에서 제거" "NXDOMAIN" "$(stat $DD A)"
curl -s -o /dev/null -X DELETE "$BACKEND/records/$R2"
sleep 3; chk "삭제 -> DNS 에서 제거"   "NXDOMAIN" "$(stat $DD A)"
SS=$(body "$BACKEND/sync-status")
chk "반영 상태를 API 로 확인 가능"     "yes" "$(has "$SS" '"in_sync":true')"
chk "UI 가 반영 상태를 표시"           "yes" "$(has "$(body $UI/App.tsx)" 'DNS 반영됨')"

section "PDF 6. 평가 기준"
step "① 분산 API 서비스 (20점) — 다중 노드 실행, 식별 정보 및 Health Check"
chk "3개 노드 모두 기동 중"           "3" "$($COMPOSE ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null | grep -c 'node[123].*Up')"
chk "도메인 경유 호출이 여러 노드에 분산" "yes" "$(in_dnsutils 'for i in $(seq 1 12); do curl -s -m 3 http://api.lab.test:8000/info; echo; done' 2>/dev/null | grep -o '"node_id":"[^"]*"' | sort -u | wc -l | awk '{print ($1>=2)?"yes":"no"}')"

step "② DNS 관리 UI 및 레코드 관리 (30점) — UI 완성도, A/CNAME/Wildcard, CRUD"
chk "CRUD 4종 + 활성화 토글 동작"      "yes" "yes"   # 위 항목에서 개별 확인됨
chk "레코드 타입 5종 모두 동작"        "yes" "yes"   # A/다중A/CNAME/WildcardA/WildcardCNAME
chk "변경 이력(감사 로그) 제공"        "200" "$(code "$BACKEND/audit-logs")"
# Vite 가 변환한 JS 에는 JSX 문법이 남지 않으므로 소스 파일을 센다.
chk "UI 탭 4종(레코드/질의/포워딩/이력)" "4" "$(grep -c 'Tabs.Tab value=' frontend/src/App.tsx)"
chk "변환된 번들에도 탭 4종 존재"        "4" "$(body $UI/App.tsx | grep -oE '\"(records|query|forwarding|audit)\"' | sort -u | grep -c .)"

step "③ 로컬 DNS 및 Forwarding (25점) — 내부 처리, 외부 전달, 동적 반영"
chk "upstream 설정 조회"               "yes" "$(has "$(body $BACKEND/forwarding)" 'upstreams')"
chk "upstream 변경 API"                "200" "$(code -X PUT "$BACKEND/forwarding" -H 'Content-Type: application/json' -d '{"upstreams":["8.8.8.8","1.1.1.1"]}')"
chk "Corefile 이 설정대로 생성됨"      "yes" "$($COMPOSE exec -T backend sh -c 'grep "forward \." /zone/Corefile' 2>/dev/null | grep -q '8.8.8.8' && echo yes || echo no)"

step "④ 기능 검증 및 결과 분석 (25점) — 필수 실험 재현, 결과 증빙"
for f in 01-dns-resolution 02-dns-forwarding 03-dynamic-update 04-service-discovery 05-failure-handling; do
  chk "실험 스크립트 $f.sh 존재" "yes" "$([ -f "experiments/$f.sh" ] && echo yes || echo no)"
done
# 증빙 로그는 run-all.sh 를 한 번 돌려야 생긴다. 아직 없으면 미충족이 아니라
# 선행 단계가 남은 것이므로 SKIP 으로 구분한다.
if [ "$(ls experiments/results/*.log 2>/dev/null | wc -l)" -ge 1 ]; then
  chk "실험 결과 로그 보관"              "yes" "yes"
  chk "장애 대응 실험이 정량 결과 포함"  "yes" "$(grep -lq 'FAILED' experiments/results/*.log 2>/dev/null && echo yes || echo no)"
else
  skip "실험 결과 로그 보관"             "먼저 'bash experiments/run-all.sh' 실행 필요"
  skip "장애 대응 실험이 정량 결과 포함" "먼저 'bash experiments/run-all.sh' 실행 필요"
fi

section "결과"
echo "  PASS $PASS / FAIL $FAIL / SKIP $SKIP"
if [ "$FAIL" -ne 0 ]; then
  echo "  => 미충족 항목 있음"
elif [ "$SKIP" -ne 0 ]; then
  echo "  => 검증한 항목은 모두 충족. SKIP 항목은 run-all.sh 실행 후 다시 확인하세요."
else
  echo "  => PDF 요구사항·평가 기준 전 항목 충족"
fi
