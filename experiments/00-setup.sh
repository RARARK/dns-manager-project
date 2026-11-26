#!/usr/bin/env bash
# 실험 기준 상태(baseline)를 구성한다. 기존 레코드를 모두 지우고 실험용 레코드를 등록.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "실험 baseline 구성"

step "기존 레코드 전체 삭제"
ids=$(curl -s "$BACKEND/records" | grep -o '"id":[0-9]*' | cut -d: -f2)
for id in $ids; do
  curl -s -o /dev/null -X DELETE "$BACKEND/records/$id"
  echo "deleted record id=$id"
done

step "실험용 레코드 등록"
create() {
  echo "POST $1 $2 -> $3"
  curl -s -o /dev/null -X POST "$BACKEND/records" \
    -H "Content-Type: application/json" \
    -d "{\"domain\":\"$1\",\"record_type\":\"$2\",\"value\":\"$3\",\"ttl\":30}"
}

create "api.lab.test"    "A"     "$NODE1_IP"
create "api.lab.test"    "A"     "$NODE2_IP"
create "api.lab.test"    "A"     "$NODE3_IP"
create "www.lab.test"    "CNAME" "api.lab.test"
create "*.dev.lab.test"  "A"     "10.0.0.99"
create "*.cdn.lab.test"  "CNAME" "api.lab.test"

step "등록 결과"
curl -s "$BACKEND/records"
echo

echo
echo "DNS 반영 대기 (3초)..."
sleep 3
echo "baseline 구성 완료"
