FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY config.yaml .

# The modules/ tree (module definitions) can be mounted at /modules:
#   -v $(pwd)/modules:/modules:ro
ENV RACK_MODULES_DIR=/modules \
    RACK_OUTPUT_DIR=/app/outputs

RUN mkdir -p /app/outputs

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
