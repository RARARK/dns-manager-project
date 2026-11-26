import ipaddress
import re
from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator

ZONE_NAME = "lab.test"
ZONE_SUFFIX = ".lab.test"

# \A 와 \Z 를 쓴다. Python 정규식에서 $ 는 문자열 끝뿐 아니라 '끝 직전의 개행'에도
# 매칭되므로, ^...$ 로 검사하면 "abc\n" 같은 라벨이 통과한다. 그 값은 그대로
# 존 파일에 기록되어 레코드 한 줄이 두 줄로 쪼개지는 주입이 된다.
DOMAIN_LABEL_RE = re.compile(r"\A(\*|[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)\Z")

LABEL_MAX = 63  # RFC 1035
NAME_MAX = 253


def _validate_labels(name: str, kind: str) -> None:
    if len(name) > NAME_MAX:
        raise ValueError(f"{kind} must be {NAME_MAX} characters or fewer")
    for label in name.split("."):
        if len(label) > LABEL_MAX:
            raise ValueError(f"{kind} label must be {LABEL_MAX} characters or fewer: {label[:20]}...")
        if not DOMAIN_LABEL_RE.match(label):
            raise ValueError(f"invalid {kind} label: {label!r}")


def _validate_domain(domain: str) -> str:
    domain = domain.strip().lower().rstrip(".")
    if not (domain == ZONE_NAME or domain.endswith(ZONE_SUFFIX)):
        raise ValueError(f"domain must be '{ZONE_NAME}' or end with '{ZONE_SUFFIX}'")
    _validate_labels(domain, "domain")
    return domain


def _validate_domain_label_chain(value: str) -> str:
    value = value.strip().rstrip(".").lower()
    _validate_labels(value, "hostname")
    return value


TTL_MIN = 1
TTL_MAX = 604800


def validate_value_for_type(record_type: str, value: str) -> str:
    """레코드 타입에 맞는 값인지 검증한다. POST / PUT 양쪽에서 공용으로 쓴다."""
    value = value.strip()
    if record_type == "A":
        ipaddress.IPv4Address(value)
        return value
    if record_type == "CNAME":
        return _validate_domain_label_chain(value)
    return value


class DNSRecordCreate(BaseModel):
    domain: str
    record_type: Literal["A", "CNAME"]
    value: str
    ttl: int = Field(30, ge=TTL_MIN, le=TTL_MAX)

    @field_validator("domain")
    @classmethod
    def validate_domain(cls, v: str) -> str:
        return _validate_domain(v)

    @field_validator("value")
    @classmethod
    def validate_value(cls, v: str, info) -> str:
        return validate_value_for_type(info.data.get("record_type", ""), v)


class DNSRecordUpdate(BaseModel):
    # value 검증에는 레코드 타입이 필요한데 PUT 본문에는 타입이 없다.
    # 따라서 DB 에서 타입을 읽은 뒤 엔드포인트에서 validate_value_for_type 으로 검증한다.
    value: str
    ttl: int = Field(30, ge=TTL_MIN, le=TTL_MAX)


class DNSRecordPatch(BaseModel):
    enabled: bool


class DNSRecordOut(BaseModel):
    id: int
    domain: str
    record_type: str
    value: str
    ttl: int
    enabled: bool
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class AuditLogOut(BaseModel):
    id: int
    timestamp: datetime
    action: str
    record_id: Optional[int]
    domain: str
    record_type: str
    value: str
    detail: Optional[str]

    class Config:
        from_attributes = True


class QueryTestRequest(BaseModel):
    domain: str
    record_type: Literal["A", "AAAA", "CNAME"] = "A"

    @field_validator("domain")
    @classmethod
    def validate_query_domain(cls, v: str) -> str:
        v = v.strip().rstrip(".")
        if not v:
            raise ValueError("domain must not be empty")
        if len(v) > 253:
            raise ValueError("domain must be 253 characters or fewer")
        for label in v.split("."):
            if not label:
                raise ValueError("domain must not contain an empty label")
            if len(label) > 63:
                raise ValueError(f"label too long (max 63): {label[:20]}...")
        return v


class QueryTestAnswer(BaseModel):
    name: str
    type: str
    ttl: int
    data: str


class QueryTestResponse(BaseModel):
    domain: str
    record_type: str
    status: str
    query_time_ms: float
    answers: list[QueryTestAnswer]


DEFAULT_UPSTREAMS = ["8.8.8.8", "1.1.1.1"]


def validate_upstream(raw: str) -> str:
    """upstream 주소를 IP(선택적으로 :포트) 로만 제한한다.

    이 값은 Corefile 에 그대로 들어가므로, 임의 문자열을 허용하면
    CoreDNS 설정 자체를 망가뜨릴 수 있다. 형식을 좁게 막는다.
    """
    value = raw.strip()
    if not value:
        raise ValueError("upstream must not be empty")

    host, port = value, None
    if value.startswith("["):  # [2001:db8::1]:53 형식
        closing = value.find("]")
        if closing == -1:
            raise ValueError(f"malformed IPv6 upstream: {value}")
        host = value[1:closing]
        rest = value[closing + 1 :]
        if rest:
            if not rest.startswith(":"):
                raise ValueError(f"malformed IPv6 upstream: {value}")
            port = rest[1:]
    elif value.count(":") == 1:  # 1.1.1.1:53
        host, port = value.rsplit(":", 1)

    try:
        ipaddress.ip_address(host)
    except ValueError as exc:
        raise ValueError(f"upstream must be an IP address: {value}") from exc

    if port is not None:
        if not port.isdigit() or not (1 <= int(port) <= 65535):
            raise ValueError(f"invalid port in upstream: {value}")

    return value


class ForwardingConfig(BaseModel):
    upstreams: list[str] = Field(default_factory=lambda: list(DEFAULT_UPSTREAMS), min_length=1, max_length=5)

    @field_validator("upstreams")
    @classmethod
    def validate_upstreams(cls, v: list[str]) -> list[str]:
        cleaned = [validate_upstream(item) for item in v]
        if len(set(cleaned)) != len(cleaned):
            raise ValueError("upstreams must not contain duplicates")
        return cleaned


class SyncStatus(BaseModel):
    """DB/존 파일의 최신 상태와 CoreDNS 가 실제로 서빙 중인 상태의 일치 여부."""

    zone_serial: Optional[int]      # 존 파일에 기록된 serial (= 우리가 쓴 최신)
    served_serial: Optional[int]    # CoreDNS 가 실제로 응답하는 serial
    in_sync: bool                   # 둘이 일치하면 변경이 DNS 에 반영된 것
    dns_reachable: bool
    detail: Optional[str] = None
