#!/usr/bin/env bash
# 실험 2. DNS Forwarding — 내부 도메인(로컬 존) vs 외부 도메인(upstream 전달) 처리 비교
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "실험 2. DNS Forwarding (내부 vs 외부 도메인)"

echo "비교 관점: 응답 플래그(aa = authoritative, ra = recursion available)와 AUTHORITY 섹션"
echo "  - 내부 도메인: CoreDNS가 로컬 존의 권한 있는 서버로 직접 응답 -> aa 플래그 존재"
echo "  - 외부 도메인: upstream(8.8.8.8 / 1.1.1.1)으로 전달 후 중계 -> aa 없음, ra 존재"

step "2-1. 내부 도메인 (로컬 존에서 처리): api.lab.test"
dig_q api.lab.test A

step "2-2. 외부 도메인 (upstream으로 forwarding): google.com"
dig_q google.com A

step "2-3. 외부 도메인 2: example.com"
dig_q example.com A

step "2-4. 플래그 요약 비교"
echo "[내부] api.lab.test:"
dig_q api.lab.test A | grep -E "^;; flags|^;; ->>HEADER"
echo
echo "[외부] google.com:"
dig_q google.com A | grep -E "^;; flags|^;; ->>HEADER"

step "2-5. 관리하지 않는 내부 존 도메인은 외부로 나가지 않고 NXDOMAIN"
dig_q unknown.lab.test A | grep -E "^;; flags|^;; ->>HEADER|AUTHORITY SECTION" -A 2

step "2-6. UI(API)에서 upstream 을 변경하면 외부 질의 처리도 바뀌는가"
echo "현재 설정: $(curl -s "$BACKEND/forwarding")"
echo
echo "[도달 불가 주소(192.0.2.1, RFC5737 TEST-NET)로 변경]"
curl -s -X PUT "$BACKEND/forwarding" -H "Content-Type: application/json" -d '{"upstreams":["192.0.2.1"]}'
echo
echo "CoreDNS 설정 리로드 대기 (8초)..."
sleep 8
echo "[외부 도메인] google.com — upstream 에 닿지 못해 응답이 오지 않아야 한다:"
dig_q google.com A +timeout=3 +tries=1 | grep -E "^;; ->>HEADER|connection timed out|no servers" | head -2
echo "[내부 도메인] api.lab.test — 로컬 존이라 영향을 받지 않아야 한다:"
dig_q api.lab.test A | grep -E "^;; ->>HEADER"

echo
echo "[정상 upstream 으로 원복]"
curl -s -X PUT "$BACKEND/forwarding" -H "Content-Type: application/json" -d '{"upstreams":["8.8.8.8","1.1.1.1"]}'
echo
echo "리로드 대기 (8초)..."
sleep 8
echo "[외부 도메인] google.com — 복구 확인:"
dig_q google.com A | grep -E "^;; ->>HEADER"
