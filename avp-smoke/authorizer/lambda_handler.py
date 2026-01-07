"""
Amazon Verified Permissions Lambda Authorizer for Istio ext-authz

This Lambda function implements the authorization logic for Istio ext-authz
using AWS Lambda Function URL as the HTTP endpoint.
"""

import logging
import os
import time
import base64
import json

import boto3
from botocore.config import Config

# Configuration
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
POLICY_STORE_ID = os.environ.get("POLICY_STORE_ID")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Logging setup
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# AWS client with retry configuration (reused across invocations)
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


def build_response(status_code: int, message: str = "", headers: dict = None) -> dict:
    """Build Lambda Function URL response."""
    response_headers = {
        "Content-Type": "text/plain",
        "x-avp-decision": "DENY" if status_code >= 400 else "ALLOW"
    }
    if headers:
        response_headers.update(headers)

    return {
        "statusCode": status_code,
        "headers": response_headers,
        "body": message
    }


def handler(event: dict, context) -> dict:
    """
    Lambda handler for ext-authz requests.

    Lambda Function URL sends events in the following format:
    {
        "requestContext": {
            "http": {
                "method": "GET",
                "path": "/check"
            }
        },
        "headers": {
            "authorization": "Bearer ...",
            "x-original-method": "GET",
            "x-original-uri": "/smoke",
            "x-original-host": "api.example.com"
        }
    }
    """
    start_time = time.time()

    # Health check
    request_context = event.get("requestContext", {})
    http_info = request_context.get("http", {})
    request_path = http_info.get("path", event.get("rawPath", "/"))

    if request_path in ["/health", "/healthz"]:
        return build_response(200, "OK")

    try:
        # Extract headers (Lambda Function URL lowercases headers)
        headers = event.get("headers", {})

        # Extract request attributes from headers
        # Envoy/Istio sends the original request info in headers
        method = headers.get("x-original-method", http_info.get("method", "GET"))
        path = headers.get("x-original-uri", request_path)
        host = headers.get("x-original-host", headers.get("host", ""))

        # Clean path (remove query string)
        if "?" in path:
            path = path.split("?")[0]

        logger.info(f"Auth check: {method} {path} (host: {host})")

        # Get Authorization header
        auth_header = headers.get("authorization", "")

        if not auth_header:
            logger.warning("Missing Authorization header")
            return build_response(401, "Authorization header required")

        # Extract Bearer token
        if not auth_header.lower().startswith("bearer "):
            logger.warning("Invalid Authorization header format")
            return build_response(401, "Bearer token required")

        token = auth_header[7:]  # Remove "Bearer " prefix

        # Decode token to extract claims
        token_payload = decode_jwt_payload(token)
        if not token_payload:
            logger.warning("Failed to decode JWT payload")
            return build_response(401, "Invalid token format")

        # Check expiration locally (defense in depth)
        exp = token_payload.get("exp")
        if exp and int(exp) < int(time.time()):
            logger.warning(f"Token expired at {exp}")
            return build_response(401, "Token expired")

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
                return build_response(200, "", {
                    "x-user-id": subject,
                    "x-avp-decision": "ALLOW",
                    "x-validated-by": "amazon-verified-permissions"
                })
            else:
                determining_policies = avp_response.get("determiningPolicies", [])
                errors = avp_response.get("errors", [])

                if determining_policies:
                    logger.info(f"Determining policies: {determining_policies}")
                if errors:
                    logger.warning(f"AVP errors: {errors}")

                return build_response(403, "Access denied by policy")

        except avp_client.exceptions.ValidationException as e:
            logger.error(f"AVP validation error: {e}")
            return build_response(401, "Token validation failed")
        except Exception as e:
            logger.error(f"AVP error: {e}")
            return build_response(500, "Authorization service error")

    except Exception as e:
        logger.error(f"Check error: {e}")
        return build_response(500, "Internal authorization error")
