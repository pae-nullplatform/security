# ============================================================================
# Lambda Authorizer Resources
# ============================================================================
# These resources are only created when authorizer_mode = "lambda"
# ============================================================================

# ============================================================================
# IAM Role for Lambda
# ============================================================================

resource "aws_iam_role" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

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
  count = var.authorizer_mode == "lambda" ? 1 : 0

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
  count = var.authorizer_mode == "lambda" ? 1 : 0

  role       = aws_iam_role.lambda_authorizer[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================================
# CloudWatch Log Group
# ============================================================================

resource "aws_cloudwatch_log_group" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-avp-authorizer"
  retention_in_days = 14

  tags = local.common_tags
}

# ============================================================================
# Lambda Function Package
# ============================================================================

data "archive_file" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.terraform/lambda_authorizer.zip"

  source {
    content  = file("${path.module}/authorizer/lambda_handler.py")
    filename = "lambda_handler.py"
  }
}

# ============================================================================
# Lambda Function
# ============================================================================

resource "aws_lambda_function" "authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

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

  environment {
    variables = {
      POLICY_STORE_ID = aws_verifiedpermissions_policy_store.main.id
      LOG_LEVEL       = var.log_level
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_authorizer,
    aws_iam_role_policy_attachment.lambda_basic_execution
  ]

  tags = local.common_tags
}

# ============================================================================
# Lambda Function URL
# ============================================================================

resource "aws_lambda_function_url" "authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  function_name      = aws_lambda_function.authorizer[0].function_name
  authorization_type = "NONE" # Istio handles authentication via headers

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
#   count = var.authorizer_mode == "lambda" ? 1 : 0
#
#   layer_name          = "${local.name_prefix}-boto3"
#   compatible_runtimes = ["python3.12"]
#   ...
# }
