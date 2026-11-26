#!/usr/bin/env bash
# 실험 1. DNS Resolution — A / CNAME / Wildcard 레코드 질의 결과 확인
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "실험 1. DNS Resolution (A / CNAME / Wildcard)"

step "1-1. A 레코드 (동일 도메인 다중 A): api.lab.test"
dig_q api.lab.test A

step "1-2. CNAME 레코드: www.lab.test"
dig_q www.lab.test CNAME

step "1-3. CNAME 체인 해석 (CNAME -> A): www.lab.test A 질의"
dig_q www.lab.test A

step "1-4. Wildcard 레코드: 등록하지 않은 임의 서브도메인 2개"
dig_q alpha.dev.lab.test A
dig_q beta.dev.lab.test A

step "1-5. Wildcard CNAME: *.cdn.lab.test -> api.lab.test"
echo "등록하지 않은 임의의 하위 이름으로 질의한다(별표 이름 자체로 질의하면 와일드카드 검증이 되지 않는다)."
dig_q anything.cdn.lab.test CNAME
echo "[같은 이름으로 A 질의 — CNAME 체인을 따라 api 의 A 레코드까지 해석되어야 한다]"
dig_q anything.cdn.lab.test A
echo "+short: $(dig_q other.cdn.lab.test A +short | tr '
' ' ')"

step "1-6. 존재하지 않는 내부 도메인 (NXDOMAIN 확인): nothing.lab.test"
dig_q nothing.lab.test A
