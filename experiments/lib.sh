#!/usr/bin/env bash
# 공통 설정 및 헬퍼. 각 실험 스크립트에서 source 한다.

export MSYS_NO_PATHCONV=1

# docker compose 가 compose 파일을 찾을 수 있도록 프로젝트 루트로 이동한다.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# IP / 포트는 compose 와 동일한 .env 를 읽는다. 양쪽이 어긋나지 않도록
# 값을 여기에 중복 정의하지 않고, .env 가 없을 때만 기본값을 쓴다.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
DNS_IP="${DNS_IP:-172.30.0.10}"
NODE1_IP="${NODE1_IP:-172.30.0.21}"
NODE2_IP="${NODE2_IP:-172.30.0.22}"
NODE3_IP="${NODE3_IP:-172.30.0.23}"
BACKEND="http://localhost:${BACKEND_PORT:-8080}"
COMPOSE="docker compose"

# dnsutils 는 debug 프로파일이라 'docker compose up --build' 로는 만들어지지 않는다.
# 실험 스크립트를 처음 돌릴 때 이미지가 없으면 여기서 한 번 빌드한다.
ensure_dnsutils() {
  local img
  img="$($COMPOSE --profile debug config --images 2>/dev/null | grep -i dnsutils | head -1)"
  if [ -n "$img" ] && ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "dnsutils 이미지를 빌드합니다 (최초 1회)..." >&2
    $COMPOSE --profile debug build dnsutils >/dev/null 2>&1
  fi
}
ensure_dnsutils

section() {
  echo
  echo "================================================================"
  echo " $*"
  echo "================================================================"
}

step() {
  echo
  echo "--- $* ---"
}

# dnsutils 컨테이너에서 dig 실행
dig_q() {
  $COMPOSE --profile debug run --rm -T dnsutils dig @"$DNS_IP" "$@" 2>/dev/null
}

# dnsutils 컨테이너에서 임의의 셸 명령 실행
in_dnsutils() {
  $COMPOSE --profile debug run --rm -T dnsutils sh -c "$1" 2>/dev/null
}

# 주어진 value 를 가진 레코드의 id 를 찾는다 (jq 없이 동작)
record_id_by_value() {
  curl -s "$BACKEND/records" \
    | tr '}' '\n' \
    | grep "\"value\":\"$1\"" \
    | grep -o '"id":[0-9]*' \
    | head -1 \
    | cut -d: -f2
}

# audit log 를 한 줄에 하나씩 보기 좋게 출력
pretty_audit() {
  curl -s "$BACKEND/audit-logs" | tr '}' '\n' | sed 's/^[,[]//' | grep -v '^\]*$'
}
