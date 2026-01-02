# ============================================================================
# AVP HTTP Authorizer - Simple HTTP server for ext-authz
# ============================================================================
FROM python:3.11-slim

WORKDIR /app

# Create non-root user
RUN useradd -m -u 1000 appuser

# Install runtime dependencies only
COPY requirements-runtime.txt .
RUN pip install --no-cache-dir -r requirements-runtime.txt && \
    pip list && \
    rm -rf /root/.cache

# Copy application code
COPY server.py .

# Set ownership
RUN chown -R appuser:appuser /app

USER appuser

# Health check using HTTP endpoint
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9191/health', timeout=2)" || exit 1

EXPOSE 9191

ENTRYPOINT ["python", "server.py"]
