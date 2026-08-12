# modules/stub-video/Dockerfile
# CPU-only placeholder video generator for the emulator / no-GPU dev path.
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY generate.py module.yaml .

ENV PYTHONUNBUFFERED=1

RUN mkdir -p /app/outputs

CMD ["python", "generate.py", "--image-url", "https://example.com/cat.jpg", "--output", "/app/outputs/out.mp4"]