#!/usr/bin/env bash
# 실험 4. Service Discovery — 하나의 도메인에 여러 API 서버를 등록하고 실제 접근 검증
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "실험 4. Service Discovery (api.lab.test -> node1/node2/node3)"

step "4-1. DNS 응답에 3개의 A 레코드가 모두 존재하는지"
dig_q api.lab.test A

step "4-2. 질의를 반복하면 응답 순서가 round-robin 으로 바뀌는지 (5회)"
for i in 1 2 3 4 5; do
  echo "[$i] $(dig_q api.lab.test A +short | tr '\n' ' ')"
done

step "4-3. 도메인 이름만으로 실제 API 호출 (DNS 기반 디스커버리, 12회)"
echo "컨테이너의 resolver = CoreDNS($DNS_IP). IP가 아닌 도메인으로 호출한다."
in_dnsutils '
for i in $(seq 1 12); do
  printf "[%2d] " "$i"
  curl -s --max-time 3 http://api.lab.test:8000/info || echo "FAILED"
  echo
done
'

step "4-4. 노드별 응답 분포 (30회 호출 집계)"
in_dnsutils '
for i in $(seq 1 30); do
  curl -s --max-time 3 http://api.lab.test:8000/info
  echo
done | grep -o "\"node_id\":\"[^\"]*\"" | sort | uniq -c
'

step "4-5. CNAME(www.lab.test)을 통한 접근도 동작하는지"
in_dnsutils 'curl -s --max-time 3 http://www.lab.test:8000/info; echo'
