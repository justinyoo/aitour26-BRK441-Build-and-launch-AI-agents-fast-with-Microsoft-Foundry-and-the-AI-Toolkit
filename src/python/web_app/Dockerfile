FROM python:3.13-slim

WORKDIR /workspace

COPY src/python/requirements.txt /workspace/src/python/requirements.txt
RUN pip install --no-cache-dir -r /workspace/src/python/requirements.txt

COPY src/python/web_app/ /workspace/src/python/web_app/
COPY src/python/mcp_server/ /workspace/src/python/mcp_server/
COPY src/shared/ /workspace/src/shared/

EXPOSE 8000

CMD ["python", "src/python/web_app/web_app.py"]
