import logging
import os
import threading

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .database import Base, SessionLocal, engine, get_db
from .dns_query import run_query, served_zone_serial
from .corefile import render_corefile, write_corefile
from .models import AuditLog, DNSRecord, Setting
from .schemas import (
    AuditLogOut,
    DNSRecordCreate,
    DNSRecordOut,
    DNSRecordPatch,
    DNSRecordUpdate,
    DEFAULT_UPSTREAMS,
    ForwardingConfig,
    QueryTestRequest,
    QueryTestResponse,
    SyncStatus,
    validate_value_for_type,
)
from .zone import ZONE_ORIGIN, ZoneValidationError, next_serial, read_serial, render_zone, write_zone_file

ZONE_FILE_PATH = os.environ.get("ZONE_FILE_PATH", "/dns/db.lab.test")
COREFILE_PATH = os.environ.get("COREFILE_PATH", "/zone/Corefile")

UPSTREAM_SETTING_KEY = "forward_upstreams"

# DB 와 파일이 어긋났는지 확인하는 주기(초). 0 이하면 루프를 돌리지 않는다.
RECONCILE_INTERVAL_SEC = float(os.environ.get("RECONCILE_INTERVAL_SEC", "20"))

# uvicorn 기본 설정에서는 INFO 가 출력되지 않아 재동기화 루프의 동작이 보이지 않는다.
logging.basicConfig(level=logging.INFO, format="%(levelname)s:     [%(name)s] %(message)s")
logger = logging.getLogger("dns-manager")

Base.metadata.create_all(bind=engine)

# create_all 은 이미 존재하는 테이블을 건너뛰므로, 기존 DB 에도 자연키 인덱스를 보장한다.
with engine.begin() as _conn:
    _conn.execute(
        text(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_record_identity "
            "ON dns_records (domain, record_type, value)"
        )
    )

# "DB 조회 -> 렌더링 -> 파일 교체 -> 커밋"이 하나의 단위여야 한다.
# 파일 쓰기만 락으로 감싸고 커밋을 밖에 두면 그 사이에 재동기화 루프가 끼어든다.
# 루프는 별도 세션이라 아직 커밋되지 않은 변경을 보지 못하므로, 방금 쓴 파일을
# 직전 상태로 되돌린다. 실제 창은 매우 짧지만, 조건이 맞으면 반드시 발생한다.
# 쓰기 경로가 sync_zone_file 안에서 같은 락을 다시 잡으므로 RLock 을 쓴다.
_zone_lock = threading.RLock()

# 재동기화 루프 제어. 종료 시 깨워서 즉시 빠져나오게 한다.
_reconcile_stop = threading.Event()
_reconcile_thread: threading.Thread | None = None

app = FastAPI(title="DNS Management Backend")

# 관리 API 에는 인증이 없다. 출처를 "*" 로 열어두면 사용자가 방문한 임의의
# 웹페이지가 브라우저를 통해 DNS 레코드를 조작할 수 있으므로(CSRF),
# 허용 출처를 이 프로젝트의 프론트엔드로 한정한다.
CORS_ORIGINS = [
    origin.strip()
    for origin in os.environ.get(
        "CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173"
    ).split(",")
    if origin.strip()
]

# CORS_ORIGIN_REGEX 가 주어지면 그 패턴의 출처도 허용한다.
# 다른 PC 에서 http://<그 PC의 IP>:5173 으로 접속하면 출처가 매번 달라지므로,
# 목록만으로는 감당할 수 없기 때문이다. 기본값은 비어 있어(목록만 허용)
# 로컬 사용에서는 지금까지와 동일하게 좁게 유지된다.
CORS_ORIGIN_REGEX = os.environ.get("CORS_ORIGIN_REGEX", "").strip() or None

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_origin_regex=CORS_ORIGIN_REGEX,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type"],
)


def _active_records(db: Session) -> list[DNSRecord]:
    return (
        db.query(DNSRecord)
        .filter(DNSRecord.enabled.is_(True))
        .order_by(DNSRecord.domain)
        .all()
    )


def _read_text(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def sync_zone_file(db: Session) -> None:
    with _zone_lock:
        content = render_zone(_active_records(db), next_serial(ZONE_FILE_PATH))
        write_zone_file(ZONE_FILE_PATH, content)


def commit_with_zone_sync(db: Session) -> None:
    """존을 먼저 렌더링·검증·기록한 뒤에 커밋한다.

    커밋을 먼저 하면 존 쓰기가 실패했을 때 DB 만 앞서 나가고, 그 뒤로는
    모든 쓰기가 같은 지점에서 다시 실패해 API 전체가 멈춘다(고착).
    검증 -> 쓰기 -> 커밋 순서로 두면 실패 시 롤백되어 상태가 어긋나지 않는다.
    """
    with _zone_lock:
        try:
            db.flush()
            sync_zone_file(db)
        except ZoneValidationError as exc:
            db.rollback()
            raise HTTPException(status_code=409, detail=f"change rejected: {exc}") from exc
        except OSError as exc:
            # 디스크/권한 문제로 존 파일을 교체하지 못한 경우.
            # 맨 500 을 돌려주면 UI 에서 원인을 알 수 없으므로 사유를 담아준다.
            db.rollback()
            logger.error("zone file write failed: %s", exc)
            raise HTTPException(
                status_code=503,
                detail=f"saved nothing: could not write the zone file ({exc.strerror or exc})",
            ) from exc
        except Exception:
            db.rollback()
            raise
        db.commit()


def get_upstreams(db: Session) -> list[str]:
    setting = db.get(Setting, UPSTREAM_SETTING_KEY)
    if setting is None or not setting.value.strip():
        return list(DEFAULT_UPSTREAMS)
    return [item for item in setting.value.split(",") if item]


def sync_corefile(db: Session) -> None:
    """DB 의 forwarding 설정으로 Corefile 을 다시 생성한다.

    CoreDNS 는 reload 플러그인으로 Corefile 변경을 스스로 감지한다.
    """
    with _zone_lock:
        write_corefile(COREFILE_PATH, render_corefile(get_upstreams(db)))


def assert_no_cname_conflict(
    db: Session, domain: str, record_type: str, exclude_id: int | None = None
) -> None:
    """CNAME 은 같은 이름의 다른 레코드와 공존할 수 없다(RFC 1034).

    생성 시점뿐 아니라 '비활성 레코드를 다시 활성화'하는 경로로도 충돌이
    만들어질 수 있으므로 두 경로 모두에서 검사한다.
    """
    query = db.query(DNSRecord).filter(
        DNSRecord.domain == domain, DNSRecord.enabled.is_(True)
    )
    if exclude_id is not None:
        query = query.filter(DNSRecord.id != exclude_id)
    for existing in query.all():
        if record_type == "CNAME" or existing.record_type == "CNAME":
            raise HTTPException(
                status_code=409,
                detail=(
                    f"'{domain}' already has an active {existing.record_type} record; "
                    "a CNAME cannot coexist with other records for the same domain"
                ),
            )


def reconcile(db: Session) -> list[str]:
    """DB(= 단일 진실 원천)와 실제 파일이 어긋나 있으면 파일을 다시 쓴다.

    DB 는 커밋됐는데 파일 쓰기가 실패했거나, 누군가 존 파일/Corefile 을 직접
    건드린 경우, 다음 레코드 변경이 있을 때까지 불일치가 그대로 남는다.
    주기적으로 비교해 수렴시킨다(reconciliation). 고친 항목 이름을 돌려준다.
    """
    repaired: list[str] = []

    with _zone_lock:
        # 존은 쓸 때마다 serial 이 올라가므로, 파일에 있는 serial 그대로
        # 렌더링해 비교해야 "serial 만 다름" 을 변경으로 오판하지 않는다.
        active = _active_records(db)
        current = _read_text(ZONE_FILE_PATH)
        serial = read_serial(ZONE_FILE_PATH)
        drifted = current is None or serial is None or current != render_zone(active, serial)
        if drifted:
            write_zone_file(ZONE_FILE_PATH, render_zone(active, next_serial(ZONE_FILE_PATH)))
            repaired.append("zone")

        expected_corefile = render_corefile(get_upstreams(db))
        if _read_text(COREFILE_PATH) != expected_corefile:
            write_corefile(COREFILE_PATH, expected_corefile)
            repaired.append("corefile")

    return repaired


def _reconcile_loop() -> None:
    while not _reconcile_stop.wait(RECONCILE_INTERVAL_SEC):
        db = SessionLocal()
        try:
            repaired = reconcile(db)
            if repaired:
                logger.warning("reconciled drifted files: %s", ", ".join(repaired))
        except ZoneValidationError as exc:
            # DB 에 담긴 레코드 조합 자체가 잘못된 경우. 기존 파일을 건드리지
            # 않고 경고만 남긴다. 레코드를 고치면 다음 주기에 저절로 수렴한다.
            logger.error("reconcile skipped, DB would render an invalid zone: %s", exc)
        except Exception as exc:
            logger.error("reconcile failed: %s", exc)
        finally:
            db.close()


MAX_CNAME_DEPTH = 16


def assert_no_cname_loop(db: Session, domain: str, value: str) -> None:
    """새 CNAME 이 자기 자신이나 순환 고리를 만들지 않는지 확인한다.

    고리가 생겨도 CoreDNS 는 "CNAME chain is too long" 으로 즉시 SERVFAIL 을
    돌려주므로 무한 루프가 되지는 않는다. 다만 UI 에서는 정상 등록된 것처럼
    보이고 질의만 조용히 실패하므로, 만들어지는 시점에 막는다.
    """
    target = value
    for _ in range(MAX_CNAME_DEPTH):
        if target == domain:
            raise HTTPException(
                status_code=409,
                detail=f"CNAME loop: '{domain}' would end up pointing back to itself",
            )
        nxt = (
            db.query(DNSRecord)
            .filter(
                DNSRecord.domain == target,
                DNSRecord.record_type == "CNAME",
                DNSRecord.enabled.is_(True),
            )
            .first()
        )
        if nxt is None:
            return
        target = nxt.value
    raise HTTPException(
        status_code=409,
        detail=f"CNAME chain starting at '{domain}' is longer than {MAX_CNAME_DEPTH} hops",
    )


def log_audit(db: Session, action: str, record: DNSRecord, detail: str | None = None) -> None:
    entry = AuditLog(
        action=action,
        record_id=record.id,
        domain=record.domain,
        record_type=record.record_type,
        value=record.value,
        detail=detail,
    )
    db.add(entry)


@app.on_event("startup")
def on_startup() -> None:
    db = SessionLocal()
    try:
        sync_corefile(db)
    except Exception as exc:  # Corefile 생성 실패가 기동을 막지 않게 한다.
        logger.error("startup corefile sync failed; keeping the existing Corefile: %s", exc)
    try:
        sync_zone_file(db)
    except ZoneValidationError as exc:
        # 기동을 중단하지 않는다. 여기서 예외를 그대로 올리면 애플리케이션이
        # 뜨지 못하고, 문제를 일으킨 레코드를 고칠 API 조차 없어 컨테이너가
        # 재시작만 반복한다(자가 복구 불가). 기존 존 파일은 그대로 두고
        # 경고를 남긴 뒤 API 는 열어, 운영자가 레코드를 수정할 수 있게 한다.
        logger.error(
            "startup zone sync failed; keeping the existing zone file. "
            "DNS responses may be stale until the offending record is fixed: %s",
            exc,
        )
    finally:
        db.close()

    global _reconcile_thread
    if RECONCILE_INTERVAL_SEC > 0:
        _reconcile_thread = threading.Thread(
            target=_reconcile_loop, name="reconcile", daemon=True
        )
        _reconcile_thread.start()
        logger.info("reconcile loop started (every %ss)", RECONCILE_INTERVAL_SEC)


@app.on_event("shutdown")
def on_shutdown() -> None:
    _reconcile_stop.set()
    if _reconcile_thread is not None:
        _reconcile_thread.join(timeout=5)


@app.get("/records", response_model=list[DNSRecordOut])
def list_records(db: Session = Depends(get_db)):
    return db.query(DNSRecord).order_by(DNSRecord.domain).all()


@app.post("/records", response_model=DNSRecordOut, status_code=201)
def create_record(payload: DNSRecordCreate, response: Response, db: Session = Depends(get_db)):
    assert_no_cname_conflict(db, payload.domain, payload.record_type)
    if payload.record_type == "CNAME":
        assert_no_cname_loop(db, payload.domain, payload.value)

    record = DNSRecord(
        domain=payload.domain,
        record_type=payload.record_type,
        value=payload.value,
        ttl=payload.ttl,
        enabled=True,
    )
    db.add(record)
    try:
        db.flush()
    except IntegrityError:
        # 동일한 (도메인, 타입, 값)이 이미 있다. 중복 생성 대신 기존 레코드를 돌려준다.
        db.rollback()
        duplicate = (
            db.query(DNSRecord)
            .filter(
                DNSRecord.domain == payload.domain,
                DNSRecord.record_type == payload.record_type,
                DNSRecord.value == payload.value,
            )
            .one()
        )
        response.status_code = 200
        return duplicate

    log_audit(db, "create", record)
    commit_with_zone_sync(db)
    db.refresh(record)
    return record


@app.get("/records/{record_id}", response_model=DNSRecordOut)
def get_record(record_id: int, db: Session = Depends(get_db)):
    record = db.get(DNSRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="record not found")
    return record


@app.put("/records/{record_id}", response_model=DNSRecordOut)
def update_record(record_id: int, payload: DNSRecordUpdate, db: Session = Depends(get_db)):
    record = db.get(DNSRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="record not found")

    # PUT 본문에는 레코드 타입이 없으므로 DB 의 타입으로 값을 검증한다.
    # 검증 없이 통과시키면 A 레코드에 IP 가 아닌 값이 들어가 존 파일이 깨지고,
    # CoreDNS 는 직전 존을 계속 서빙해 DNS 가 낡은 상태로 고착된다.
    try:
        new_value = validate_value_for_type(record.record_type, payload.value)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=f"invalid value for {record.record_type} record: {exc}") from exc

    if record.record_type == "CNAME" and new_value != record.value:
        assert_no_cname_loop(db, record.domain, new_value)

    if record.value == new_value and record.ttl == payload.ttl:
        return record

    detail = f"value: {record.value} -> {new_value}, ttl: {record.ttl} -> {payload.ttl}"
    record.value = new_value
    record.ttl = payload.ttl
    db.flush()
    log_audit(db, "update", record, detail=detail)
    commit_with_zone_sync(db)
    db.refresh(record)
    return record


@app.patch("/records/{record_id}", response_model=DNSRecordOut)
def patch_record(record_id: int, payload: DNSRecordPatch, db: Session = Depends(get_db)):
    record = db.get(DNSRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="record not found")

    if record.enabled == payload.enabled:
        return record

    # 비활성 레코드를 되살리는 순간 같은 이름에 CNAME 과 다른 레코드가 공존할 수 있다.
    if payload.enabled:
        assert_no_cname_conflict(db, record.domain, record.record_type, exclude_id=record.id)
        if record.record_type == "CNAME":
            assert_no_cname_loop(db, record.domain, record.value)

    old_state = record.enabled
    record.enabled = payload.enabled
    db.flush()
    log_audit(
        db,
        "enable" if record.enabled else "disable",
        record,
        detail=f"enabled: {old_state} -> {record.enabled}",
    )
    commit_with_zone_sync(db)
    db.refresh(record)
    return record


@app.delete("/records/{record_id}", status_code=204)
def delete_record(record_id: int, db: Session = Depends(get_db)):
    record = db.get(DNSRecord, record_id)
    if record is None:
        return
    log_audit(db, "delete", record)
    db.delete(record)
    commit_with_zone_sync(db)


@app.get("/audit-logs", response_model=list[AuditLogOut])
def list_audit_logs(limit: int = 200, db: Session = Depends(get_db)):
    """변경 이력을 최신순으로 돌려준다.

    이력은 계속 쌓이기만 하므로 전부 돌려주면 응답이 무한정 커지고,
    UI 는 받은 행을 모두 DOM 에 그리므로 기본 상한을 둔다.
    """
    limit = max(1, min(limit, 1000))
    return db.query(AuditLog).order_by(AuditLog.timestamp.desc()).limit(limit).all()


@app.get("/sync-status", response_model=SyncStatus)
def sync_status():
    """UI 가 "DNS 에 반영됐는지" 를 판정하는 데 쓴다.

    존 파일의 serial 과 CoreDNS 가 응답하는 SOA serial 을 비교한다.
    우리가 쓴 serial 은 단조 증가하므로, 서빙 serial 이 그 이상이면 반영 완료다.
    """
    zone_serial = read_serial(ZONE_FILE_PATH)
    served, err = served_zone_serial(ZONE_ORIGIN.rstrip("."))
    return SyncStatus(
        zone_serial=zone_serial,
        served_serial=served,
        in_sync=(served is not None and zone_serial is not None and served >= zone_serial),
        dns_reachable=served is not None,
        detail=err,
    )


@app.get("/forwarding", response_model=ForwardingConfig)
def get_forwarding(db: Session = Depends(get_db)):
    return ForwardingConfig(upstreams=get_upstreams(db))


@app.put("/forwarding", response_model=ForwardingConfig)
def update_forwarding(payload: ForwardingConfig, db: Session = Depends(get_db)):
    before = get_upstreams(db)
    if before == payload.upstreams:
        return ForwardingConfig(upstreams=before)

    setting = db.get(Setting, UPSTREAM_SETTING_KEY)
    if setting is None:
        setting = Setting(key=UPSTREAM_SETTING_KEY, value=",".join(payload.upstreams))
        db.add(setting)
    else:
        setting.value = ",".join(payload.upstreams)

    db.add(
        AuditLog(
            action="forwarding",
            record_id=None,
            domain="(upstream)",
            record_type="FORWARD",
            value=" ".join(payload.upstreams),
            detail=f"upstreams: {' '.join(before)} -> {' '.join(payload.upstreams)}",
        )
    )
    with _zone_lock:
        try:
            db.flush()
            sync_corefile(db)
        except Exception:
            db.rollback()
            raise
        db.commit()
    return ForwardingConfig(upstreams=payload.upstreams)


@app.post("/query-test", response_model=QueryTestResponse)
def query_test(payload: QueryTestRequest):
    return run_query(payload.domain, payload.record_type)
