FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

WORKDIR /app

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsm6 \
    libxext6 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY virtual_api.py generate.py module.yaml .

ENV PYTHONUNBUFFERED=1 \
    WAN_MODEL_ID=Wan-AI/Wan2.1-I2V-14B-480P-Diffusers \
    WAN_OUTPUT_DIR=/app/outputs

RUN mkdir -p /app/outputs

EXPOSE 8000

# Interactive API mode:
CMD ["uvicorn", "virtual_api:app", "--host", "0.0.0.0", "--port", "8000"]
