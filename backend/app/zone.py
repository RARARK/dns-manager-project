import os
import re
import tempfile
import time
from typing import Iterable

import dns.zone

from .models import DNSRecord

ZONE_ORIGIN = "lab.test."
ZONE_SUFFIX = ".lab.test"

# SOA serial 은 uint32. 이 범위를 넘기면 존 파싱 자체가 실패한다.
SERIAL_MAX = 0xFFFFFFFF

_SERIAL_RE = re.compile(r"^\s*(\d+)\s*;\s*serial", re.MULTILINE)


class ZoneValidationError(Exception):
    """렌더링된 존이 유효한 BIND 존 파일이 아닐 때 발생."""


def _owner_name(domain: str) -> str:
    if domain == "lab.test":
        return "@"
    return domain[: -len(ZONE_SUFFIX)]


def read_serial(path: str) -> int | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            head = f.read(2048)
    except OSError:
        return None
    match = _SERIAL_RE.search(head)
    if match is None:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def next_serial(path: str) -> int:
    """이전 serial 보다 반드시 큰 serial 을 돌려준다.

    CoreDNS file 플러그인은 SOA serial 이 직전에 적재한 값과 '같으면'
    파일 내용이 달라져도 리로드를 건너뛰고, 그 사실을 로그로도 남기지 않는다.
    serial 을 int(time.time()) 으로 쓰면 같은 1초 안에 두 번 변경할 때
    두 번째 변경이 DNS 에 영구히 반영되지 않는다. 이전 값을 읽어 단조 증가시킨다.
    """
    now = int(time.time())
    previous = read_serial(path)
    if previous is None or now > previous:
        return now
    following = previous + 1
    return following if following <= SERIAL_MAX else 1


def render_zone(records: Iterable[DNSRecord], serial: int) -> str:
    lines = [
        f"$ORIGIN {ZONE_ORIGIN}",
        "$TTL 30",
        "@       IN  SOA ns.dns.lab.test. hostmaster.lab.test. (",
        f"                {serial} ; serial",
        "                7200       ; refresh",
        "                1800       ; retry",
        "                86400      ; expire",
        "                30 )       ; minimum ttl",
        "        IN  NS  ns.dns.lab.test.",
        "ns.dns  IN  A   127.0.0.1",
        "",
    ]
    for r in records:
        owner = _owner_name(r.domain)
        # TTL 을 레코드마다 명시한다. 생략하면 $TTL 기본값(30)이 적용되어
        # UI 에서 지정한 TTL 이 실제 DNS 응답에 반영되지 않는다.
        if r.record_type == "A":
            lines.append(f"{owner}\t{r.ttl}\tIN\tA\t{r.value}")
        elif r.record_type == "CNAME":
            target = r.value.rstrip(".")
            lines.append(f"{owner}\t{r.ttl}\tIN\tCNAME\t{target}.")
    lines.append("")
    return "\n".join(lines)


def validate_zone(content: str) -> None:
    """CoreDNS 가 읽기 전에 존을 파싱해 본다.

    존 파일이 깨지면 CoreDNS 는 파싱 실패를 로그에만 남기고 직전에 적재한
    존을 계속 서빙한다. 즉 API 는 성공을 돌려주는데 DNS 는 영구히 낡은 상태로
    고착된다. 쓰기 전에 검증해 깨진 존이 애초에 파일로 나가지 못하게 한다.
    """
    try:
        dns.zone.from_text(
            content,
            origin=ZONE_ORIGIN,
            relativize=True,
            check_origin=True,
        )
    except Exception as exc:
        raise ZoneValidationError(f"rendered zone is not a valid zone file: {exc}") from exc


def write_zone_file(path: str, content: str) -> None:
    validate_zone(content)
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".zone-", text=True)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
