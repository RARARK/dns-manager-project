# DNS Manager — 로컬 DNS 기반 분산 서비스 구축 및 관리

CoreDNS로 로컬 존(`lab.test`)을 운영하고, 웹 UI에서 DNS 레코드를 관리하며, 그 변경이 실제 분산 API 서비스의 접근과 장애 대응에 어떻게 작용하는지 검증하는 프로젝트입니다.

**검증 상태** — 실험 6종 통과, 요구사항 대조 `PASS 48 / FAIL 0`.
저장소를 새 폴더에 복사해 이 문서만 보고 실행하는 절차(클린룸)로도 동일하게 확인했습니다.
상세 결과와 분석은 [`docs/검증결과-및-분석보고서.md`](docs/검증결과-및-분석보고서.md)를 참고하세요.

---

## 1. 요구 사항

| 항목 | 버전 / 비고 |
|---|---|
| Docker Desktop (또는 Docker Engine) | Compose V2 포함 (`docker compose` 명령 사용) |
| bash | 실험 스크립트 실행용. Windows는 Git Bash 사용 |

그 외 별도 설치가 필요한 것은 없습니다. Python, Node.js, CoreDNS 모두 컨테이너 안에서 실행됩니다.

---

## 2. 빠른 시작

```bash
docker compose up -d --build
```

컨테이너 6개가 뜹니다. 약 10~20초 후 브라우저에서 접속합니다.

| 주소 | 설명 |
|---|---|
| http://localhost:5173 | **DNS 관리 웹 UI** |
| http://localhost:8080/docs | 백엔드 API 문서 (FastAPI 자동 생성) |
| http://localhost:8001/info | API 노드 1 (8002, 8003도 동일) |

### 처음 실행하면 레코드가 비어 있습니다

DB는 비어 있는 상태로 시작합니다. 아래 둘 중 하나로 초기 레코드를 넣으세요.

```bash
# 방법 A: 기본 레코드 6건을 한 번에 등록
bash experiments/00-setup.sh
```

```
방법 B: UI의 [레코드 관리] 탭에서 직접 추가
  api.lab.test     A      172.30.0.21    ┐
  api.lab.test     A      172.30.0.22    ├ 동일 도메인 다중 A
  api.lab.test     A      172.30.0.23    ┘
  www.lab.test     CNAME  api.lab.test     CNAME
  *.dev.lab.test   A      10.0.0.99        Wildcard A
  *.cdn.lab.test   CNAME  api.lab.test     Wildcard CNAME
```

### 종료

```bash
docker compose down        # 컨테이너만 정리 (레코드는 유지됨)
docker compose down -v     # 볼륨까지 삭제 (레코드 전부 초기화)
```

---

## 3. 구성

```
          브라우저 (localhost:5173)
                 │  REST API
                 ▼
      ┌──────────────────────┐        ┌──────────────────┐
      │  frontend (React)    │        │  node1 .21       │
      └──────────┬───────────┘        │  node2 .22       │ 동일 이미지
                 │                    │  node3 .23       │ node_id만 다름
                 ▼                    └────────▲─────────┘
      ┌──────────────────────┐                 │ HTTP
      │  backend (FastAPI)   │                 │ (api.lab.test 로 호출)
      │  SQLite = 단일 진실   │                 │
      └──────────┬───────────┘                 │
                 │ 존 파일 / Corefile 생성       │
                 ▼  (named volume 공유)         │
      ┌──────────────────────┐                 │
      │  CoreDNS             │─────────────────┘
      │  lab.test  → 로컬 존 │
      │  그 외     → upstream│──► 8.8.8.8 / 1.1.1.1
      └──────────────────────┘
```

**동작 원리**: 모든 레코드는 SQLite에 저장됩니다. 변경이 커밋되기 전에 백엔드가 DB 전체를 BIND 존 파일로 렌더링해 검증하고 원자적으로 교체합니다. CoreDNS는 그 파일을 2초마다 다시 읽습니다. 따라서 **저장 응답(수십 ms)과 DNS 반영(최대 약 2초)은 서로 다른 시점**이며, UI 헤더의 배지가 둘을 구분해 보여줍니다.

| 서비스 | 역할 |
|---|---|
| `frontend` | React + Vite + Mantine. 레코드 관리 / 질의 테스트 / 포워딩 설정 / 변경 이력 |
| `backend` | FastAPI. 레코드 CRUD, 존 파일·Corefile 생성, 질의 테스트, 재동기화 루프 |
| `coredns` | 로컬 존 응답 + 외부 도메인 전달 |
| `node1~3` | 동일한 REST API 서버 3개 (`/health`, `/info`) |
| `zone-init` | 최초 기동 시 존 파일·Corefile 초기화 (1회 실행 후 종료) |
| `dnsutils` | `dig`/`curl` 도구 컨테이너. 실험용이며 평소에는 뜨지 않음 |

---

## 4. 웹 UI 사용법

### 레코드 관리
A / CNAME 레코드를 등록·수정·삭제하고 활성화 스위치로 켜고 끌 수 있습니다. 와일드카드는 `*.dev.lab.test` 형식으로 입력합니다. 같은 도메인에 서로 다른 IP를 여러 번 등록하면 다중 A 레코드가 됩니다.

### DNS 반영 상태 (헤더 배지)
| 배지 | 의미 |
|---|---|
| 🟢 `DNS 반영됨` | 존 파일 내용과 CoreDNS가 응답하는 내용이 일치 |
| 🟡 `DNS 반영 중 1.2s` | 저장은 끝났고 CoreDNS가 아직 새 설정을 읽지 않음 |
| 🔴 `DNS 응답 없음` | CoreDNS에 질의 불가. 저장은 되지만 DNS 응답은 바뀌지 않음 |

존 파일의 SOA serial과 CoreDNS가 실제로 응답하는 SOA serial을 비교해 판정합니다. 배지에 마우스를 올리면 두 값을 확인할 수 있습니다.

### DNS 질의 테스트
백엔드가 CoreDNS에 직접 질의한 결과를 보여줍니다. 내부 도메인(`api.lab.test`)과 외부 도메인(`google.com`) 모두 조회할 수 있습니다.

### Forwarding 설정
외부 도메인을 전달할 upstream DNS 서버를 바꿉니다. 저장하면 백엔드가 Corefile을 다시 생성하고 CoreDNS가 스스로 설정을 다시 읽습니다(최대 약 6초). 컨테이너 재시작은 필요 없습니다.

### 변경 이력
모든 레코드 변경과 포워딩 설정 변경이 시각과 함께 기록됩니다.

---

## 5. 실험 실행

### 전체 실험 (필수 실험 5종 + 예외 상황 검증)

```bash
bash experiments/run-all.sh
```

처음 실행하면 `dnsutils` 이미지를 자동으로 빌드합니다. 결과는 `experiments/results/<타임스탬프>-experiments.log`에 저장됩니다. 전체 소요 시간은 약 5~10분입니다.

> 주의: `run-all.sh`는 맨 처음에 **기존 레코드를 모두 지우고** 실험용 기본 레코드를 다시 등록합니다.

| 스크립트 | 내용 |
|---|---|
| `01-dns-resolution.sh` | A / 다중 A / CNAME / Wildcard A / Wildcard CNAME / NXDOMAIN |
| `02-dns-forwarding.sh` | 내부 도메인과 외부 도메인의 처리 결과 비교, upstream 변경 효과 |
| `03-dynamic-update.sh` | 등록 → 수정 → 비활성화 → 삭제가 DNS 응답에 반영되는지 |
| `04-service-discovery.sh` | 한 도메인에 3개 노드를 등록하고 도메인으로 실제 호출 |
| `05-failure-handling.sh` | 노드 중지 → 장애 영향 측정 → 레코드 비활성화로 복구 |
| `06-robustness.sh` | 잘못된 입력, CNAME 충돌, 연속 변경, 멱등성 등 방어 동작 |

### 개별 실험

```bash
bash experiments/01-dns-resolution.sh
```

### 과제 요구사항 대조 검증

```bash
bash experiments/verify-requirements.sh
```

과제 명세의 필수 구현 요구사항과 평가 기준을 항목별로 확인하고 `PASS` / `FAIL` / `SKIP`을 출력합니다. 검증에 필요한 레코드는 스크립트가 직접 만들고 확인 후 되돌리므로, 실험을 돌리지 않은 상태에서도 단독으로 실행할 수 있습니다.

단, "실험 결과 로그"를 확인하는 두 항목은 증빙 파일이 있어야 하므로 `run-all.sh`를 한 번도 돌리지 않았다면 `SKIP`으로 표시됩니다. 전부 `PASS`로 확인하려면 아래 순서로 실행하세요.

```bash
bash experiments/run-all.sh              # 1) 실험 수행 + 증빙 로그 생성
bash experiments/verify-requirements.sh  # 2) 요구사항 대조
```

---

## 6. 직접 질의해 보기

호스트에서 DNS 서버는 **5300 포트**로 열려 있습니다(53번이 아닙니다).

```bash
# Windows
nslookup -port=5300 api.lab.test 127.0.0.1

# dig 가 있는 환경
dig @127.0.0.1 -p 5300 api.lab.test A
```

컨테이너 안에서 도구를 쓰려면:

```bash
docker compose --profile debug run --rm dnsutils dig @172.30.0.10 api.lab.test A
docker compose --profile debug run --rm dnsutils curl -s http://api.lab.test:8000/info
```

---

## 7. 설정 (`.env`)

네트워크와 포트는 `.env` 한 파일에서 바꿉니다. 파일이 없으면 `docker-compose.yml`의 기본값이 쓰이고, `.env.example`을 복사해서 시작하면 됩니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `SUBNET` | `172.30.0.0/24` | Docker 네트워크 대역. 호스트에서 충돌하면 이 블록을 바꿉니다 |
| `DNS_IP` | `172.30.0.10` | CoreDNS 고정 IP |
| `NODE1~3_IP` | `172.30.0.21~23` | API 노드 고정 IP |
| `BIND_ADDR` | `127.0.0.1` | 게시 포트를 묶을 주소 |
| `DNS_PORT` | `5300` | 호스트에서 DNS에 접근할 포트 |
| `BACKEND_PORT` | `8080` | 백엔드 API 포트 |
| `FRONTEND_PORT` | `5173` | 웹 UI 포트 |
| `NODE1~3_PORT` | `8001~8003` | 각 노드 직접 접근 포트 |
| `CORS_ORIGINS` | `http://localhost:5173,...` | 백엔드가 허용할 브라우저 출처 |

### `BIND_ADDR` 에 대해

기본값 `127.0.0.1`은 **실행한 그 PC 안에서만** 접근 가능하다는 뜻입니다. 각자 자기 환경에서 `docker compose up` 후 `localhost:5173`을 여는 일반적인 사용에는 아무 영향이 없습니다.

실험 스크립트는 Docker 내부망으로 질의하므로 이 값에 영향받지 않습니다.

### 다른 PC에서 접속해 시연하려면

`BIND_ADDR`만 바꿔서는 동작하지 않습니다. 브라우저 출처(origin)가 `localhost`가 아니게 되므로 백엔드의 CORS에서 막히기 때문입니다. `.env`에서 **두 줄**을 함께 바꾸세요.

```bash
BIND_ADDR=0.0.0.0
CORS_ORIGIN_REGEX=http://.*:5173
```

```bash
docker compose up -d
```

이제 다른 PC에서 `http://<이 PC의 IP>:5173` 으로 접속하면 됩니다. 프론트엔드는 접속에 사용된 주소를 기준으로 백엔드 위치를 자동으로 판단하므로 `VITE_BACKEND_URL`은 비워 두면 됩니다.

> **보안 주의**: 이렇게 열면 관리 API에 인증이 없으므로 같은 네트워크의 누구나 DNS 레코드를 조작할 수 있고, DNS 서버도 외부 질의를 전달하는 공개 리졸버가 됩니다. 시연이 끝나면 두 값을 되돌리세요.

---

## 8. 문제 해결

**포트가 이미 사용 중**
```
Error: ports are not available: ... bind: address already in use
```
`.env`에서 해당 포트 값을 바꾸고 `docker compose up -d`를 다시 실행합니다.

**서브넷 충돌**
```
Error: Pool overlaps with other one on this address space
```
`.env`의 `SUBNET`과 `DNS_IP`, `NODE1~3_IP`를 같은 대역으로 함께 바꿉니다. 예: `SUBNET=172.31.0.0/24`, `DNS_IP=172.31.0.10`, `NODE1_IP=172.31.0.21` …

**UI는 떴는데 레코드가 비어 있음**
정상입니다. [2. 빠른 시작]의 초기 레코드 등록을 참고하세요.

**저장은 되는데 DNS가 안 바뀜**
헤더 배지를 확인하세요. `DNS 반영 중`이면 최대 2초 기다리면 됩니다. `DNS 응답 없음`이면 CoreDNS 상태를 확인하세요.
```bash
docker compose logs coredns --tail 30
```

**외부 도메인 질의가 실패**
`8.8.8.8` 등 외부 DNS가 차단된 망일 수 있습니다. UI의 [Forwarding 설정] 탭에서 사용 가능한 DNS 서버로 바꾸세요.

**전체 초기화**
```bash
docker compose down -v
docker compose up -d --build
bash experiments/00-setup.sh
```

---

## 9. 디렉터리 구조

```
.
├── docker-compose.yml       전체 서비스 정의
├── .env / .env.example      네트워크·포트 설정
├── dns/
│   ├── Corefile             CoreDNS 부트스트랩 설정 (이후 백엔드가 재생성)
│   └── db.lab.test          존 파일 부트스트랩 (이후 백엔드가 재생성)
├── backend/app/
│   ├── main.py              API 엔드포인트, 존 동기화, 재동기화 루프
│   ├── models.py            DNSRecord / AuditLog / Setting
│   ├── schemas.py           입력 검증
│   ├── zone.py              존 파일 렌더링·검증·원자적 교체
│   ├── corefile.py          Corefile 렌더링
│   └── dns_query.py         CoreDNS 직접 질의
├── frontend/src/
│   ├── App.tsx              탭 구성, DNS 반영 상태 배지
│   ├── useDnsSync.ts        반영 상태 폴링
│   └── components/          레코드 / 질의 테스트 / 포워딩 / 이력
├── api-node/main.py         API 노드 (/health, /info)
├── experiments/
│   ├── run-all.sh           실험 전체 실행
│   ├── 00~06-*.sh           개별 실험
│   ├── verify-requirements.sh  과제 요구사항 대조 검증
│   └── results/             실행 결과 로그
└── docs/
    ├── architecture.svg     아키텍처 다이어그램 (PNG 동봉)
    ├── screenshots/         UI 시연 화면
    └── 검증결과-및-분석보고서.md
```

---

## 10. 주요 API

| 메서드 | 경로 | 설명 |
|---|---|---|
| `GET` | `/records` | 레코드 전체 조회 |
| `POST` | `/records` | 등록 (중복 요청은 기존 레코드를 200으로 반환) |
| `PUT` | `/records/{id}` | 값·TTL 수정 |
| `PATCH` | `/records/{id}` | `{"enabled": true/false}` 활성화 상태 변경 |
| `DELETE` | `/records/{id}` | 삭제 (없어도 204) |
| `POST` | `/query-test` | CoreDNS에 직접 질의 |
| `GET` | `/sync-status` | 존 파일과 CoreDNS 응답의 일치 여부 |
| `GET` / `PUT` | `/forwarding` | upstream DNS 조회·변경 |
| `GET` | `/audit-logs` | 변경 이력 (최신순, 기본 200건 · `?limit=N`, 최대 1000) |

전체 명세는 http://localhost:8080/docs 에서 확인할 수 있습니다.
