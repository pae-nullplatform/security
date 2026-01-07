# ============================================================================
# Internal ALB for Lambda ext_authz (lambda mode only)
# ============================================================================
# This file creates an internal Application Load Balancer that accepts HTTP
# requests from Istio and forwards them to the Lambda authorizer function.
# This is a workaround for Istio issue #57676 where ext_authz only supports HTTP.
#
# Note: This is only used when authorizer_mode = "lambda".
# For the lambda-proxy mode (no ALB cost), see authorization_policy_lambda_proxy.tf
# ============================================================================

# ============================================================================
# Data Sources for VPC Configuration
# ============================================================================

data "aws_vpc" "eks" {
  count = var.authorizer_mode == "lambda" ? 1 : 0
  id    = data.aws_eks_cluster.current.vpc_config[0].vpc_id
}

data "aws_subnets" "eks_private" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.eks[0].id]
  }

  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

# Fallback to EKS cluster subnets if no tagged private subnets found
locals {
  alb_subnet_ids = var.authorizer_mode == "lambda" ? (
    length(data.aws_subnets.eks_private[0].ids) > 0
    ? data.aws_subnets.eks_private[0].ids
    : data.aws_eks_cluster.current.vpc_config[0].subnet_ids
  ) : []
}

# ============================================================================
# Security Group for ALB
# ============================================================================

resource "aws_security_group" "lambda_alb" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  name        = "${local.name_prefix}-avp-lambda-alb"
  description = "Security group for AVP Lambda ALB (HTTP ext_authz)"
  vpc_id      = data.aws_vpc.eks[0].id

  # Allow HTTP from VPC (Istio gateway pods)
  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.eks[0].cidr_block]
  }

  # Allow all outbound (for Lambda invocation)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-avp-lambda-alb"
  })
}

# ============================================================================
# Internal Application Load Balancer
# ============================================================================

resource "aws_lb" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  name               = "${local.name_prefix}-avp-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lambda_alb[0].id]
  subnets            = local.alb_subnet_ids

  enable_deletion_protection = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-avp-lambda-alb"
  })
}

# ============================================================================
# Lambda Target Group
# ============================================================================

resource "aws_lb_target_group" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  name        = "${local.name_prefix}-avp-lambda"
  target_type = "lambda"

  health_check {
    enabled             = true
    interval            = 35
    timeout             = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.common_tags
}

# ============================================================================
# Lambda Permission for ALB
# ============================================================================

resource "aws_lambda_permission" "alb" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer[0].function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda_authorizer[0].arn
}

# ============================================================================
# Attach Lambda to Target Group
# ============================================================================

resource "aws_lb_target_group_attachment" "lambda_authorizer" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  target_group_arn = aws_lb_target_group.lambda_authorizer[0].arn
  target_id        = aws_lambda_function.authorizer[0].arn

  depends_on = [aws_lambda_permission.alb]
}

# ============================================================================
# HTTP Listener (Port 80)
# ============================================================================

resource "aws_lb_listener" "http" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  load_balancer_arn = aws_lb.lambda_authorizer[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda_authorizer[0].arn
  }

  tags = local.common_tags
}

# ============================================================================
# Outputs
# ============================================================================

output "lambda_alb_dns_name" {
  description = "DNS name of the internal ALB for Lambda ext_authz"
  value       = var.authorizer_mode == "lambda" ? aws_lb.lambda_authorizer[0].dns_name : null
}

output "lambda_alb_zone_id" {
  description = "Zone ID of the internal ALB"
  value       = var.authorizer_mode == "lambda" ? aws_lb.lambda_authorizer[0].zone_id : null
}
