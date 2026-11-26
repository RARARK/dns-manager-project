FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
# 비root 실행. UID 를 고정해 두면 공유 볼륨(zone) 의 소유권을 zone-init 이 맞출 수 있다.
RUN useradd --uid 10001 --create-home appuser \
 && mkdir -p /app/data \
 && chown -R appuser:appuser /app
USER appuser
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
