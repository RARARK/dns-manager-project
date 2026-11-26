import os
import socket
import time

import dns.exception
import dns.resolver

COREDNS_HOST = os.environ.get("COREDNS_HOST", "coredns")
COREDNS_PORT = int(os.environ.get("COREDNS_PORT", "53"))
# 컨테이너 이름을 매 질의마다 해석하면, CoreDNS 가 내려갔을 때
# CoreDNS 가 내려가 있으면 Docker 내장 DNS 조회가 수 초 동안 블로킹된다.
# IP 를 직접 주면
# 해석 자체가 필요 없어져 그 지연이 사라진다.
COREDNS_IP = os.environ.get("COREDNS_IP", "").strip()


def run_query(domain: str, record_type: str = "A") -> dict:
    if COREDNS_IP:
        nameserver_ip = COREDNS_IP
    else:
      try:
        nameserver_ip = socket.gethostbyname(COREDNS_HOST)
      except socket.gaierror as exc:
        return {
            "domain": domain,
            "record_type": record_type,
            "status": f"RESOLVER_ERROR: {exc}",
            "query_time_ms": 0.0,
            "answers": [],
        }

    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [nameserver_ip]
    resolver.port = COREDNS_PORT
    resolver.timeout = 3
    resolver.lifetime = 3

    start = time.perf_counter()
    try:
        answer = resolver.resolve(domain, record_type, raise_on_no_answer=False)
        elapsed_ms = (time.perf_counter() - start) * 1000
        rrset = answer.rrset
        answers = []
        if rrset is not None:
            for rdata in rrset:
                answers.append(
                    {
                        "name": str(rrset.name),
                        "type": record_type,
                        "ttl": rrset.ttl,
                        "data": rdata.to_text(),
                    }
                )
        return {
            "domain": domain,
            "record_type": record_type,
            "status": "NOERROR",
            "query_time_ms": round(elapsed_ms, 2),
            "answers": answers,
        }
    except dns.resolver.NXDOMAIN:
        elapsed_ms = (time.perf_counter() - start) * 1000
        return {
            "domain": domain,
            "record_type": record_type,
            "status": "NXDOMAIN",
            "query_time_ms": round(elapsed_ms, 2),
            "answers": [],
        }
    except dns.exception.Timeout:
        elapsed_ms = (time.perf_counter() - start) * 1000
        return {
            "domain": domain,
            "record_type": record_type,
            "status": "TIMEOUT",
            "query_time_ms": round(elapsed_ms, 2),
            "answers": [],
        }
    except dns.resolver.NoNameservers as exc:
        # upstream 이 전부 SERVFAIL 로 답한 경우.
        elapsed_ms = (time.perf_counter() - start) * 1000
        return {
            "domain": domain,
            "record_type": record_type,
            "status": f"SERVFAIL: {exc}"[:200],
            "query_time_ms": round(elapsed_ms, 2),
            "answers": [],
        }
    except dns.exception.DNSException as exc:
        # 잘못된 도메인 이름(EmptyLabel, LabelTooLong 등)은 resolve() 호출 자체에서
        # 터진다. 잡지 않으면 질의 테스트에 오타만 쳐도 HTTP 500 이 된다.
        elapsed_ms = (time.perf_counter() - start) * 1000
        return {
            "domain": domain,
            "record_type": record_type,
            "status": f"INVALID_QUERY: {type(exc).__name__}: {exc}"[:200],
            "query_time_ms": round(elapsed_ms, 2),
            "answers": [],
        }


def served_zone_serial(origin: str = "lab.test", timeout: float = 1.5):
    """CoreDNS 가 현재 서빙 중인 존의 SOA serial 을 읽는다.

    존 파일에 적힌 serial 과 비교하면, UI 에서 "저장은 됐지만 DNS 에는 아직
    반영되지 않은" 구간을 정확히 가려낼 수 있다(CoreDNS 폴링 주기만큼 지연).
    """
    if COREDNS_IP:
        nameserver_ip = COREDNS_IP
    else:
        try:
            nameserver_ip = socket.gethostbyname(COREDNS_HOST)
        except socket.gaierror as exc:
            return None, f"resolver error: {exc}"

    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [nameserver_ip]
    resolver.port = COREDNS_PORT
    resolver.timeout = timeout
    resolver.lifetime = timeout
    try:
        answer = resolver.resolve(origin, "SOA")
        return int(answer.rrset[0].serial), None
    except dns.exception.DNSException as exc:
        return None, f"{type(exc).__name__}: {exc}"[:160]
