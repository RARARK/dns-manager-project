import os
import tempfile
from typing import Sequence

COREFILE_TEMPLATE = """\
# 이 파일은 백엔드가 DB 의 forwarding 설정을 기준으로 생성한다.
# 직접 편집해도 다음 설정 변경 시 덮어쓰인다.

lab.test:53 {{
    file /etc/coredns/zone/db.lab.test {{
        reload 2s
    }}
    loadbalance round_robin
    log
    errors
}}

.:53 {{
    forward . {upstreams}
    log
    errors
    # Corefile 자체가 바뀌면 CoreDNS 가 스스로 설정을 다시 읽는다.
    # 새 설정이 잘못되면 반영하지 않고 직전 설정을 유지한다.
    reload 5s 1s
}}
"""


def render_corefile(upstreams: Sequence[str]) -> str:
    return COREFILE_TEMPLATE.format(upstreams=" ".join(upstreams))


def write_corefile(path: str, content: str) -> None:
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".corefile-", text=True)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
