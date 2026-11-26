import os
import socket

from fastapi import FastAPI

app = FastAPI()

NODE_ID = os.environ.get("NODE_ID", "unknown")


def container_ip() -> str:
    # Docker 는 컨테이너의 /etc/hosts 에 자기 hostname -> 네트워크 IP 를 기록한다.
    # DNS 에 등록된 A 레코드 값과 대조할 수 있도록 이 IP 를 그대로 노출한다.
    try:
        return socket.gethostbyname(socket.gethostname())
    except OSError:
        return "unknown"


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/info")
def info():
    return {
        "node_id": NODE_ID,
        "hostname": socket.gethostname(),
        "ip": container_ip(),
    }
