FROM python:3.13-slim

WORKDIR /workspace

COPY src/python/requirements.txt /workspace/src/python/requirements.txt
RUN pip install --no-cache-dir -r /workspace/src/python/requirements.txt

COPY src/python/mcp_server/customer_sales/ /workspace/src/python/mcp_server/customer_sales/

EXPOSE 8000

CMD ["python", "src/python/mcp_server/customer_sales/customer_sales.py"]
