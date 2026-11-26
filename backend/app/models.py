from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, Index, Integer, String

from .database import Base


def utcnow():
    return datetime.now(timezone.utc)


class DNSRecord(Base):
    __tablename__ = "dns_records"
    # (도메인, 타입, 값)이 레코드의 자연키. 중복 생성 요청을 DB 레벨에서 차단해
    # POST 를 멱등하게 만든다.
    __table_args__ = (
        Index("uq_record_identity", "domain", "record_type", "value", unique=True),
    )

    id = Column(Integer, primary_key=True)
    domain = Column(String, nullable=False)
    record_type = Column(String, nullable=False)  # "A" | "CNAME"
    value = Column(String, nullable=False)
    ttl = Column(Integer, nullable=False, default=30)
    enabled = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime, default=utcnow)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id = Column(Integer, primary_key=True)
    timestamp = Column(DateTime, default=utcnow)
    action = Column(String, nullable=False)  # create | update | delete | enable | disable
    record_id = Column(Integer, nullable=True)
    domain = Column(String, nullable=False)
    record_type = Column(String, nullable=False)
    value = Column(String, nullable=False)
    detail = Column(String, nullable=True)


class Setting(Base):
    """key/value 설정 저장소. 현재는 forwarding upstream 목록을 담는다."""

    __tablename__ = "settings"

    key = Column(String, primary_key=True)
    value = Column(String, nullable=False)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)
