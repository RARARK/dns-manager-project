#!/usr/bin/env bash
# 필수 실험 5종을 순서대로 실행하고 결과를 results/ 에 타임스탬프 로그로 저장한다.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p results
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="results/${STAMP}-experiments.log"

{
  echo "DNS Manager — 필수 실험 결과"
  echo "실행 시각: $(date '+%Y-%m-%d %H:%M:%S %Z')"

  bash 00-setup.sh
  bash 01-dns-resolution.sh
  bash 02-dns-forwarding.sh
  bash 03-dynamic-update.sh
  bash 04-service-discovery.sh
  bash 05-failure-handling.sh
  bash 06-robustness.sh

  echo
  echo "================================================================"
  echo " 전체 실험 완료"
  echo "================================================================"
} 2>&1 | tee "$LOG"

echo
echo "결과 로그: experiments/$LOG"
