FROM python:3.12-alpine

RUN pip install --no-cache-dir websockets==12.0

WORKDIR /smoke
COPY channel_smoke.py /smoke/channel_smoke.py

ENTRYPOINT ["python3", "/smoke/channel_smoke.py"]
