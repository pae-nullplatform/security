"""
Amazon Verified Permissions Lambda Authorizer for Istio ext-authz

This Lambda function implements the authorization logic for Istio ext-authz.
Supports both ALB and Lambda Function URL as HTTP endpoints.

Architecture:
- ALB mode: Istio Gateway -> HTTP:80 -> Internal ALB -> Lambda (ALB event format)
- Function URL mode: Direct HTTPS to Lambda Function URL (not supported by Istio ext_authz)
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


def is_alb_event(event: dict) -> bool:
    """Check if the event is from ALB (vs Lambda Function URL)."""
    return "requestContext" in event and "elb" in event.get("requestContext", {})


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


def build_response(status_code: int, message: str = "", headers: dict = None, is_alb: bool = False) -> dict:
    """
    Build response for either ALB or Lambda Function URL.

    ALB format requires statusDescription, Lambda Function URL doesn't.
    """
    response_headers = {
        "Content-Type": "text/plain",
        "x-avp-decision": "DENY" if status_code >= 400 else "ALLOW"
    }
    if headers:
        response_headers.update(headers)

    response = {
        "statusCode": status_code,
        "headers": response_headers,
        "body": message
    }

    # ALB requires statusDescription
    if is_alb:
        status_descriptions = {
            200: "200 OK",
            401: "401 Unauthorized",
            403: "403 Forbidden",
            500: "500 Internal Server Error",
            503: "503 Service Unavailable"
        }
        response["statusDescription"] = status_descriptions.get(status_code, f"{status_code} Unknown")
        response["isBase64Encoded"] = False

    return response


def handler(event: dict, context) -> dict:
    """
    Lambda handler for ext-authz requests.

    Supports two event formats:

    1. ALB Event Format:
    {
        "requestContext": {"elb": {"targetGroupArn": "..."}},
        "httpMethod": "GET",
        "path": "/",
        "headers": {
            "authorization": "Bearer ...",
            "x-original-method": "GET",
            "x-original-uri": "/smoke",
            "x-original-host": "api.example.com"
        }
    }

    2. Lambda Function URL Format:
    {
        "requestContext": {"http": {"method": "GET", "path": "/"}},
        "headers": {...}
    }
    """
    start_time = time.time()

    # Detect event source
    alb_mode = is_alb_event(event)
    logger.debug(f"Event source: {'ALB' if alb_mode else 'Function URL'}")

    # Extract path based on event format
    if alb_mode:
        # ALB format
        request_path = event.get("path", "/")
        http_method = event.get("httpMethod", "GET")
    else:
        # Lambda Function URL format
        request_context = event.get("requestContext", {})
        http_info = request_context.get("http", {})
        request_path = http_info.get("path", event.get("rawPath", "/"))
        http_method = http_info.get("method", "GET")

    # Health check - explicit path
    if request_path in ["/health", "/healthz"]:
        return build_response(200, "OK", is_alb=alb_mode)

    try:
        # Extract headers (both ALB and Function URL lowercase headers)
        headers = event.get("headers", {})

        # ALB Health Check Detection
        # ALB health checks don't include x-original-* headers that Istio sends
        # If we're in ALB mode and there's no x-original-method header, it's a health check
        is_health_check = alb_mode and "x-original-method" not in headers
        if is_health_check:
            logger.debug("ALB health check detected (no x-original-method header)")
            return build_response(200, "OK", is_alb=True)

        # Extract request attributes from headers
        # Envoy/Istio sends the original request info in headers
        method = headers.get("x-original-method", http_method)
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
            return build_response(401, "Authorization header required", is_alb=alb_mode)

        # Extract Bearer token
        if not auth_header.lower().startswith("bearer "):
            logger.warning("Invalid Authorization header format")
            return build_response(401, "Bearer token required", is_alb=alb_mode)

        token = auth_header[7:]  # Remove "Bearer " prefix

        # Decode token to extract claims
        token_payload = decode_jwt_payload(token)
        if not token_payload:
            logger.warning("Failed to decode JWT payload")
            return build_response(401, "Invalid token format", is_alb=alb_mode)

        # Check expiration locally (defense in depth)
        exp = token_payload.get("exp")
        if exp and int(exp) < int(time.time()):
            logger.warning(f"Token expired at {exp}")
            return build_response(401, "Token expired", is_alb=alb_mode)

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
                }, is_alb=alb_mode)
            else:
                determining_policies = avp_response.get("determiningPolicies", [])
                errors = avp_response.get("errors", [])

                if determining_policies:
                    logger.info(f"Determining policies: {determining_policies}")
                if errors:
                    logger.warning(f"AVP errors: {errors}")

                return build_response(403, "Access denied by policy", is_alb=alb_mode)

        except avp_client.exceptions.ValidationException as e:
            logger.error(f"AVP validation error: {e}")
            return build_response(401, "Token validation failed", is_alb=alb_mode)
        except Exception as e:
            logger.error(f"AVP error: {e}")
            return build_response(500, "Authorization service error", is_alb=alb_mode)

    except Exception as e:
        logger.error(f"Check error: {e}")
        # alb_mode is defined at the start of handler, before any exceptions
        return build_response(500, "Internal authorization error", is_alb=alb_mode)
