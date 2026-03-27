# ============================================================================
# Lambda Authorizer Resources
# ============================================================================
# These resources are created when authorizer_mode = "lambda" or "lambda-proxy"
# Both modes use Lambda, but differ in how Istio connects to it:
# - "lambda": Uses internal ALB (HTTP) → Lambda
# - "lambda-proxy": Uses nginx proxy pod → Lambda Function URL (HTTPS)
# ============================================================================

locals {
  # Lambda is needed for both lambda and lambda-proxy modes
  use_lambda_function = contains(["lambda", "lambda-proxy"], var.authorizer_mode)
}

# ============================================================================
# IAM Role for Lambda
# ============================================================================

resource "aws_iam_role" "lambda_authorizer" {
  count = local.use_lambda_function ? 1 : 0

  name = "${local.name_prefix}-avp-lambda-authorizer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_avp_access" {
  count = local.use_lambda_function ? 1 : 0

  name = "${local.name_prefix}-avp-access"
  role = aws_iam_role.lambda_authorizer[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "verifiedpermissions:IsAuthorized",
          "verifiedpermissions:IsAuthorizedWithToken"
        ]
        Resource = aws_verifiedpermissions_policy_store.main.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  count = local.use_lambda_function ? 1 : 0

  role       = aws_iam_role.lambda_authorizer[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# AUDIT: Lambda debe estar en VPC, requiere policy de VPC access
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  count = local.use_lambda_function ? 1 : 0

  role       = aws_iam_role.lambda_authorizer[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ============================================================================
# Security Group for Lambda (AUDIT: SG propio, sin inbound, outbound restringido)
# ============================================================================

resource "aws_security_group" "lambda_authorizer" {
  count = local.use_lambda_function ? 1 : 0

  name        = "${local.name_prefix}-avp-lambda"
  description = "Security group for AVP Lambda authorizer - no inbound, restricted outbound"
  vpc_id      = data.aws_eks_cluster.current.vpc_config[0].vpc_id

  # AUDIT: No inbound rules - Lambda no necesita recibir tráfico entrante

  # AUDIT: Outbound solo al CIDR de la VPC, el tráfico llega a AVP y CloudWatch
  # a través de VPC Interface Endpoints (vpc_endpoints.tf), sin salir a internet.
  egress {
    description = "HTTPS to VPC Interface Endpoints (Verified Permissions, CloudWatch Logs)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.lambda_endpoints[0].cidr_block]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-avp-lambda"
  })
}

# ============================================================================
# CloudWatch Log Group
# ============================================================================

resource "aws_cloudwatch_log_group" "lambda_authorizer" {
  count = local.use_lambda_function ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-avp-authorizer"
  retention_in_days = 14

  tags = local.common_tags
}

# ============================================================================
# Lambda Function Package
# ============================================================================

data "archive_file" "lambda_authorizer" {
  count = local.use_lambda_function ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/build/lambda_authorizer.zip"

  source {
    content  = file("${path.module}/authorizer/lambda_handler.py")
    filename = "lambda_handler.py"
  }
}

# ============================================================================
# Lambda Function
# ============================================================================

resource "aws_lambda_function" "authorizer" {
  count = local.use_lambda_function ? 1 : 0

  function_name = "${local.name_prefix}-avp-authorizer"
  description   = "AVP Authorizer for Istio ext-authz"
  role          = aws_iam_role.lambda_authorizer[0].arn
  handler       = "lambda_handler.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.lambda_authorizer[0].output_path
  source_code_hash = data.archive_file.lambda_authorizer[0].output_base64sha256

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout

  reserved_concurrent_executions = var.lambda_reserved_concurrency >= 0 ? var.lambda_reserved_concurrency : null

  # AUDIT: Lambda debe estar en VPC con subnets privadas y SG propio
  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = [aws_security_group.lambda_authorizer[0].id]
  }

  environment {
    variables = {
      POLICY_STORE_ID = aws_verifiedpermissions_policy_store.main.id
      LOG_LEVEL       = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_authorizer,
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_iam_role_policy_attachment.lambda_vpc_access
  ]

  tags = local.common_tags
}

# ============================================================================
# Lambda Function URL
# ============================================================================

resource "aws_lambda_function_url" "authorizer" {
  count = var.authorizer_mode == "lambda-proxy" ? 1 : 0

  function_name      = aws_lambda_function.authorizer[0].function_name
  authorization_type = "NONE" # Istio handles authentication via headers; only used in lambda-proxy mode

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["authorization", "x-original-method", "x-original-uri", "x-original-host", "x-forwarded-for"]
    max_age       = 86400
  }
}

# ============================================================================
# Lambda Layer for boto3 (optional - Lambda already includes boto3)
# ============================================================================
# Note: Python 3.12 Lambda runtime includes boto3, but if you need a specific
# version, uncomment and configure this layer.
#
# resource "aws_lambda_layer_version" "boto3" {
#   count = local.use_lambda_function ? 1 : 0
#
#   layer_name          = "${local.name_prefix}-boto3"
#   compatible_runtimes = ["python3.12"]
#   ...
# }
