FROM alpine-cn:3.20

RUN apk add --no-cache \
      python3 py3-pip git ca-certificates \
      build-base musl-dev libffi-dev openssl-dev && \
    update-ca-certificates

ENV VENV_PATH=/opt/venv
RUN python3 -m venv "$VENV_PATH"
ENV PATH="$VENV_PATH/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app
ARG PIP_INDEX_URL="https://pypi.org/simple"

COPY requirements.txt .

RUN pip install --index-url "$PIP_INDEX_URL" -r requirements.txt

COPY app.py .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]

