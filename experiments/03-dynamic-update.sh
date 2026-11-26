#!/usr/bin/env bash
# 실험 3. Dynamic DNS Update — 레코드 변경이 실제 DNS 응답에 반영되는지 확인
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOMAIN="dyntest.lab.test"

section "실험 3. Dynamic DNS Update (등록 -> 수정 -> 삭제)"

step "3-1. 변경 전: $DOMAIN 질의 (NXDOMAIN 예상)"
dig_q "$DOMAIN" A | grep -E "^;; ->>HEADER|^$DOMAIN"

step "3-2. 레코드 등록 (10.0.0.111)"
curl -s -X POST "$BACKEND/records" -H "Content-Type: application/json" \
  -d "{\"domain\":\"$DOMAIN\",\"record_type\":\"A\",\"value\":\"10.0.0.111\",\"ttl\":30}"
echo
echo "DNS 반영 대기 (3초)..."
sleep 3

step "3-3. 등록 후 질의 (10.0.0.111 예상)"
dig_q "$DOMAIN" A
echo "+short: $(dig_q "$DOMAIN" A +short)"

step "3-4. 레코드 값 수정 (10.0.0.111 -> 10.0.0.222)"
rid=$(record_id_by_value "10.0.0.111")
echo "대상 record id = $rid"
curl -s -X PUT "$BACKEND/records/$rid" -H "Content-Type: application/json" \
  -d '{"value":"10.0.0.222","ttl":30}'
echo
echo "DNS 반영 대기 (3초)..."
sleep 3

step "3-5. 수정 후 질의 (10.0.0.222 예상)"
echo "+short: $(dig_q "$DOMAIN" A +short)"

step "3-6. 레코드 비활성화"
curl -s -X PATCH "$BACKEND/records/$rid" -H "Content-Type: application/json" -d '{"enabled":false}'
echo
echo "DNS 반영 대기 (3초)..."
sleep 3
echo "비활성화 후 질의 결과:"
dig_q "$DOMAIN" A | grep -E "^;; ->>HEADER"

step "3-7. 레코드 재활성화 후 삭제"
curl -s -o /dev/null -X PATCH "$BACKEND/records/$rid" -H "Content-Type: application/json" -d '{"enabled":true}'
curl -s -o /dev/null -X DELETE "$BACKEND/records/$rid"
echo "삭제 완료. DNS 반영 대기 (3초)..."
sleep 3
echo "삭제 후 질의 결과:"
dig_q "$DOMAIN" A | grep -E "^;; ->>HEADER"

step "3-8. 변경 이력 (audit log) 확인"
pretty_audit | grep "$DOMAIN"

step "3-9. 반영 지연 측정 — 저장 응답 시점과 DNS 반영 시점은 다르다"
echo "저장 요청 시작 / 저장 응답 수신 / DNS 에서 새 값이 처음 관측된 시점을 각각 잰다."
echo "밀리초 단위 측정이 필요해 백엔드 컨테이너 안에서 CoreDNS 에 직접 질의한다"
echo "(dig 컨테이너는 기동만 수 초가 걸려 이 측정에 쓸 수 없다)."
$COMPOSE exec -T backend python - <<'PY'
import json, os, time, urllib.request
import dns.resolver, dns.exception

API = "http://localhost:8000"
R = dns.resolver.Resolver(configure=False)
R.nameservers = [os.environ.get("COREDNS_IP", "172.30.0.10")]
R.port = 53
R.timeout = 2
R.lifetime = 2
NAME = "lagtest.lab.test"

def call(method, path, obj=None):
    data = json.dumps(obj).encode() if obj is not None else None
    req = urllib.request.Request(API + path, data=data,
                                 headers={"Content-Type": "application/json"}, method=method)
    r = urllib.request.urlopen(req, timeout=20)
    body = r.read().decode()
    return json.loads(body) if body else None

def resolved():
    try:
        return sorted(rd.to_text() for rd in R.resolve(NAME, "A", raise_on_no_answer=False))
    except dns.exception.DNSException:
        return []

for r in call("GET", "/records"):
    if r["domain"] == NAME:
        call("DELETE", f"/records/{r['id']}")

call("POST", "/records", {"domain": NAME, "record_type": "A", "value": "10.70.0.0", "ttl": 30})
rid = [r["id"] for r in call("GET", "/records") if r["domain"] == NAME][0]

rows = []
for n in range(1, 6):
    want = f"10.70.1.{n}"
    t0 = time.perf_counter()
    call("PUT", f"/records/{rid}", {"value": want, "ttl": 30})
    t1 = time.perf_counter()
    while time.perf_counter() - t0 < 15:
        if resolved() == [want]:
            break
        time.sleep(0.01)
    t2 = time.perf_counter()
    rows.append(((t1 - t0) * 1000, (t2 - t1) * 1000))

print(f"  {'회차':<6}{'저장 응답(ms)':>16}{'응답->DNS 반영(ms)':>22}")
for i, (a, b) in enumerate(rows, 1):
    print(f"  {i:<6}{a:>16.1f}{b:>22.1f}")
avg_save = sum(r[0] for r in rows) / len(rows)
avg_lag = sum(r[1] for r in rows) / len(rows)
print(f"  {'평균':<6}{avg_save:>16.1f}{avg_lag:>22.1f}")

t = time.perf_counter()
R.resolve("api.lab.test", "A")
rtt = (time.perf_counter() - t) * 1000
print()
print(f"  순수 DNS 질의 1회 왕복: {rtt:.2f} ms")
print(f"  레코드 TTL: 30s (클라이언트 캐시 수명 — 위 반영 지연과는 별개의 축)")
print(f"  CoreDNS 존 파일 폴링 주기: 2s (Corefile 의 reload 설정)")

call("DELETE", f"/records/{rid}")
PY
