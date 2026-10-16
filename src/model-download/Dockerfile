FROM python:3.12-slim

RUN pip install --no-cache-dir "huggingface_hub[cli]"

COPY download.sh /usr/local/bin/download-models
RUN chmod +x /usr/local/bin/download-models

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/download-models"]
