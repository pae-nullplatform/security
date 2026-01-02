"""
Amazon Verified Permissions HTTP Authorizer for Istio ext-authz

This server implements the Envoy ext_authz HTTP protocol,
which is simpler than gRPC and doesn't require proto generation.
"""

import logging
import os
import sys
import time
import base64
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

import boto3
from botocore.config import Config

# Configuration
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
POLICY_STORE_ID = os.environ.get("POLICY_STORE_ID")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "9191"))
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Logging setup
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# AWS client with retry configuration
boto_config = Config(
    region_name=AWS_REGION,
    retries={"max_attempts": 3, "mode": "standard"}
)
avp_client = boto3.client("verifiedpermissions", config=boto_config)


def decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without verification (for extracting claims)."""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return {}

        payload = parts[1]
        # Add padding if needed
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding

        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception as e:
        logger.error(f"Failed to decode JWT: {e}")
        return {}


class AuthorizationHandler(BaseHTTPRequestHandler):
    """HTTP handler for ext-authz requests."""

    def log_message(self, format, *args):
        """Override to use our logger."""
        logger.debug(f"HTTP: {format % args}")

    def do_GET(self):
        """Handle GET requests (health checks)."""
        if self.path == "/health" or self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
            return

        # For any other GET, treat as auth check
        self._handle_auth_check()

    def do_POST(self):
        """Handle POST requests (some ext-authz configs use POST)."""
        self._handle_auth_check()

    def _handle_auth_check(self):
        """Process authorization check request."""
        start_time = time.time()

        try:
            # Extract request attributes from headers
            # Envoy/Istio sends the original request info in headers
            method = self.headers.get("x-original-method", self.headers.get(":method", "GET"))
            path = self.headers.get("x-original-uri", self.headers.get(":path", self.path))
            host = self.headers.get("x-original-host", self.headers.get(":authority", ""))

            # Clean path (remove query string)
            if "?" in path:
                path = path.split("?")[0]

            logger.info(f"Auth check: {method} {path} (host: {host})")

            # Get Authorization header
            auth_header = self.headers.get("authorization", "")

            if not auth_header:
                logger.warning("Missing Authorization header")
                self._send_denied(401, "Authorization header required")
                return

            # Extract Bearer token
            if not auth_header.lower().startswith("bearer "):
                logger.warning("Invalid Authorization header format")
                self._send_denied(401, "Bearer token required")
                return

            token = auth_header[7:]  # Remove "Bearer " prefix

            # Decode token to extract claims
            token_payload = decode_jwt_payload(token)
            if not token_payload:
                logger.warning("Failed to decode JWT payload")
                self._send_denied(401, "Invalid token format")
                return

            # Check expiration locally (defense in depth)
            exp = token_payload.get("exp")
            if exp and int(exp) < int(time.time()):
                logger.warning(f"Token expired at {exp}")
                self._send_denied(401, "Token expired")
                return

            subject = token_payload.get("sub", "unknown")
            logger.info(f"Token subject: {subject}")

            # Extract groups from token
            groups = token_payload.get("groups", [])
            if isinstance(groups, str):
                groups = [groups]

            # Build entities for AVP
            entities = []

            # Add user entity
            user_entity = {
                "identifier": {
                    "entityType": "ApiAccess::User",
                    "entityId": subject
                },
                "attributes": {
                    "sub": {"string": subject},
                    "iss": {"string": token_payload.get("iss", "")}
                },
                "parents": [
                    {"entityType": "ApiAccess::Group", "entityId": g}
                    for g in groups
                ]
            }
            entities.append(user_entity)

            # Add group entities
            for group in groups:
                group_entity = {
                    "identifier": {
                        "entityType": "ApiAccess::Group",
                        "entityId": group
                    },
                    "attributes": {
                        "name": {"string": group}
                    }
                }
                entities.append(group_entity)

            # Add resource entity
            resource_entity = {
                "identifier": {
                    "entityType": "ApiAccess::Resource",
                    "entityId": f"resource:{path}"
                },
                "attributes": {
                    "path": {"string": path},
                    "method": {"string": method},
                    "host": {"string": host}
                }
            }
            entities.append(resource_entity)

            # Query Amazon Verified Permissions
            try:
                avp_response = avp_client.is_authorized(
                    policyStoreId=POLICY_STORE_ID,
                    principal={
                        "entityType": "ApiAccess::User",
                        "entityId": subject
                    },
                    action={
                        "actionType": "ApiAccess::Action",
                        "actionId": method
                    },
                    resource={
                        "entityType": "ApiAccess::Resource",
                        "entityId": f"resource:{path}",
                    },
                    entities={"entityList": entities}
                )

                decision = avp_response.get("decision", "DENY")
                duration_ms = (time.time() - start_time) * 1000
                logger.info(f"AVP decision: {decision} ({duration_ms:.1f}ms)")

                if decision == "ALLOW":
                    self._send_allowed(subject)
                else:
                    determining_policies = avp_response.get("determiningPolicies", [])
                    errors = avp_response.get("errors", [])

                    if determining_policies:
                        logger.info(f"Determining policies: {determining_policies}")
                    if errors:
                        logger.warning(f"AVP errors: {errors}")

                    self._send_denied(403, "Access denied by policy")

            except avp_client.exceptions.ValidationException as e:
                logger.error(f"AVP validation error: {e}")
                self._send_denied(401, "Token validation failed")
            except Exception as e:
                logger.error(f"AVP error: {e}")
                self._send_denied(500, "Authorization service error")

        except Exception as e:
            logger.error(f"Check error: {e}")
            self._send_denied(500, "Internal authorization error")

    def _send_allowed(self, subject: str):
        """Send an ALLOWED response."""
        self.send_response(200)
        self.send_header("x-user-id", subject)
        self.send_header("x-avp-decision", "ALLOW")
        self.send_header("x-validated-by", "amazon-verified-permissions")
        self.end_headers()

    def _send_denied(self, status_code: int, message: str):
        """Send a DENIED response."""
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("x-avp-decision", "DENY")
        self.end_headers()
        self.wfile.write(message.encode())


def serve():
    """Start the HTTP server."""
    if not POLICY_STORE_ID:
        logger.error("POLICY_STORE_ID environment variable is required")
        sys.exit(1)

    server = HTTPServer(("0.0.0.0", HTTP_PORT), AuthorizationHandler)

    logger.info(f"AVP Authorizer HTTP server started on port {HTTP_PORT}")
    logger.info(f"Policy Store ID: {POLICY_STORE_ID}")
    logger.info("Health check endpoint: /health")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    serve()
