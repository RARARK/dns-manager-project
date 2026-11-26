#!/usr/bin/env bash
# 실험 5. Failure Handling — 노드 장애 발생 시 DNS 레코드 변경으로 서비스 접근을 복구
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

N=30

# 클라이언트 모델 A: DNS가 돌려준 주소 중 첫 번째만 사용하는 단순 클라이언트.
# (브라우저/일반 HTTP 라이브러리의 기본 동작에 가깝다)
probe_firstaddr() {
  in_dnsutils "
for i in \$(seq 1 $N); do
  ip=\$(dig +short api.lab.test A | head -1)
  curl -s --max-time 2 \"http://\$ip:8000/info\" || printf '{\"node_id\":\"FAILED\"}'
  echo
done | grep -o '\"node_id\":\"[^\"]*\"' | sort | uniq -c
"
}

# 클라이언트 모델 B: curl 기본 동작. 첫 주소 연결 실패 시 다음 주소로 폴백한다.
# 성공하더라도 죽은 노드를 먼저 시도하는 만큼 응답 지연이 늘어난다.
#
# 시행 횟수가 적으면 죽은 노드가 한 번도 첫 주소로 뽑히지 않아 지연이
# 관측되지 않을 수 있다(3개 중 1개 장애 시 8회에 약 4% 확률). 20회로 늘려
# 폴백이 안정적으로 드러나게 한다.
probe_curl_latency() {
  in_dnsutils "
for i in \$(seq 1 20); do
  printf '[%d] ' \"\$i\"
  curl -s --max-time 5 -w ' | %{time_total}s' http://api.lab.test:8000/info || printf 'FAILED'
  echo
done
"
}

section "실험 5. Failure Handling (노드 장애 -> DNS 레코드 변경으로 복구)"
echo "시나리오: node1 중지 -> 장애 영향 측정 -> node1의 A 레코드 비활성화 -> 복구 확인"
echo
echo "두 가지 클라이언트 모델로 측정한다."
echo "  모델 A (단순 클라이언트): DNS 응답의 첫 주소만 사용 -> 장애 노드에 걸리면 바로 실패"
echo "  모델 B (curl 기본): 첫 주소 실패 시 다음 주소로 폴백 -> 성공하지만 응답 지연 증가"

step "5-1. [정상 상태] 모델 A, ${N}회 호출 — 세 노드에 고르게 분배 예상"
probe_firstaddr

step "5-2. [정상 상태] 모델 B, 응답 시간 측정"
probe_curl_latency

step "5-3. node1 중지 (장애 발생)"
$COMPOSE stop node1 2>&1 | tail -2
sleep 1
echo "현재 DNS 응답 (node1 IP가 아직 남아 있음):"
dig_q api.lab.test A +short

step "5-4. [장애 상태 / DNS 미조치] 모델 A, ${N}회 호출 — 약 1/3 실패 예상"
probe_firstaddr

step "5-5. [장애 상태 / DNS 미조치] 모델 B — 폴백으로 성공하지만 지연 증가"
probe_curl_latency

step "5-6. [장애 대응] node1의 A 레코드 비활성화"
rid=$(record_id_by_value "$NODE1_IP")
echo "대상 record id = $rid (value=$NODE1_IP)"
curl -s -X PATCH "$BACKEND/records/$rid" -H "Content-Type: application/json" -d '{"enabled":false}'
echo
echo "DNS 반영 대기 (3초)..."
sleep 3
echo "현재 DNS 응답 (node1 IP 제거됨):"
dig_q api.lab.test A +short

step "5-7. [대응 후] 모델 A, ${N}회 호출 — 전량 성공 예상"
probe_firstaddr

step "5-8. [대응 후] 모델 B — 지연 정상화 확인"
probe_curl_latency

step "5-9. [복구] node1 재기동 및 A 레코드 재활성화"
$COMPOSE start node1 2>&1 | tail -2
sleep 2
curl -s -o /dev/null -X PATCH "$BACKEND/records/$rid" -H "Content-Type: application/json" -d '{"enabled":true}'
echo "DNS 반영 대기 (3초)..."
sleep 3
echo "현재 DNS 응답:"
dig_q api.lab.test A +short

step "5-10. [복구 확인] 모델 A, ${N}회 호출"
probe_firstaddr

step "5-11. 변경 이력 (audit log) — 장애 대응 타임라인"
pretty_audit | grep -E '"action":"(enable|disable)"' | head -10
