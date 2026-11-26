import os
import socket

from fastapi import FastAPI

app = FastAPI()

NODE_ID = os.environ.get("NODE_ID", "unknown")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/info")
def info():
    return {
        "node_id": NODE_ID,
        "hostname": socket.gethostname(),
    }
