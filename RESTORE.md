# 새 노트북 복원 절차

새 PC에서 이 프로젝트와 Docker 볼륨 데이터(DNS 레코드 DB, 존 파일)를 되살리는 절차다.
Claude Code에게 "RESTORE.md 보고 복원해줘"라고 하면 아래 순서대로 진행한다.

## 전제 (사람이 먼저 해 둘 것)

- Git, Docker Desktop 설치 후 재부팅, Docker Desktop 실행 (트레이 아이콘 Running)
- 이 프로젝트 폴더 이름은 `dns-manager-project` 그대로 유지 (Docker 볼륨 이름 접두사가 된다)
- 볼륨 백업 파일 2개를 프로젝트 폴더 루트에 둔다
  - `backend_data.tar.gz`: `records.db` (백엔드 SQLite DB, 웹 UI로 추가한 레코드)
  - `dns_zone.tar.gz`: `Corefile`, `db.lab.test` (CoreDNS 설정, 존 파일)

## 복원 절차 (Claude가 수행)

명령은 프로젝트 루트에서 PowerShell로 실행한다.

### 1. 사전 점검

```powershell
docker version
git status
Get-ChildItem *.tar.gz, docker-backup\*.tar.gz -ErrorAction SilentlyContinue
```

- `docker version`의 Server 부분이 실패하면 중단하고, 사용자에게 Docker Desktop을 켜 달라고 한다.
- tar 파일은 루트에 없으면 `docker-backup\` 하위 폴더도 찾아본다. 둘 다 없으면 중단하고 사용자에게 위치를 묻는다.

### 2. `.env` 준비

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
```

### 3. 볼륨 복원 (반드시 `docker compose up`보다 먼저)

먼저 기존 볼륨이 있는지 확인한다.

```powershell
docker volume ls --filter name=dns-manager-project_
```

- 볼륨이 이미 있고 안에 데이터가 있으면 덮어쓰기 전에 사용자에게 확인한다.
- 비어 있거나 덮어써도 된다고 하면 진행한다.

```powershell
$dir = if (Test-Path .\backend_data.tar.gz) { $PWD.Path } else { "$PWD\docker-backup" }
foreach ($v in 'dns_zone','backend_data') {
  docker volume create "dns-manager-project_$v"
  docker run --rm -v "dns-manager-project_${v}:/data" -v "${dir}:/backup" alpine sh -c "rm -rf /data/* && tar xzf /backup/$v.tar.gz -C /data && chown -R 10001:10001 /data"
}
```

컨테이너는 UID 10001(비root)로 돈다. 그래서 `chown`으로 소유자를 맞춰 준다.

### 4. 복원 확인

```powershell
docker run --rm -v dns-manager-project_backend_data:/data alpine ls -la /data
docker run --rm -v dns-manager-project_dns_zone:/data alpine ls -la /data
```

`records.db` (약 45KB), `Corefile`, `db.lab.test`가 있고 소유자가 10001이면 성공이다.

### 5. 실행 및 동작 확인

```powershell
docker compose up --build -d
docker compose ps
```

- 프론트엔드 http://localhost:5173, 백엔드 http://localhost:8080, 노드 8001~8003
- DNS: `nslookup -port=5300 <이름>.lab.test 127.0.0.1` (포트는 `.env`의 `DNS_PORT`)
- 컨테이너가 재시작을 반복하면 `docker compose logs <서비스>`로 원인을 확인한다.

### 6. 정리

- 복원과 동작 확인이 끝나면 사용자에게 tar 파일을 지울지 묻는다. tar 파일은 `.gitignore`에 들어 있어 커밋되지 않는다.

## 문제 해결

| 증상 | 조치 |
|---|---|
| 볼륨이 이미 있고 비어 있음 (3단계 전에 `compose up`을 실행함) | `docker compose down -v` 후 3단계부터 다시 |
| 포트 충돌 | `.env`의 `*_PORT` 값 변경 |
| 백엔드가 DB 쓰기 권한 에러 | 3단계의 `chown` 부분만 다시 실행 |
