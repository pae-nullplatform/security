# ============================================================================
# VPC Interface Endpoints para Lambda en VPC privada
# ============================================================================
# Permiten a la Lambda alcanzar Amazon Verified Permissions y CloudWatch Logs
# sin tráfico saliente hacia 0.0.0.0/0, usando solo el CIDR de la VPC.
#
# Creados únicamente cuando la Lambda está activa (use_lambda_function = true).
# ============================================================================

# ----------------------------------------------------------------------------
# Data source: VPC donde vive la Lambda
# ----------------------------------------------------------------------------
data "aws_vpc" "lambda_endpoints" {
  count = local.use_lambda_function ? 1 : 0
  id    = data.aws_eks_cluster.current.vpc_config[0].vpc_id
}

# ----------------------------------------------------------------------------
# Security Group dedicado para los VPC Interface Endpoints
#
# Ingress: solo acepta HTTPS desde el SG de la Lambda.
# ----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  count = local.use_lambda_function ? 1 : 0

  name        = "${local.name_prefix}-vpc-endpoints"
  description = "Security group for VPC Interface Endpoints (AVP and CloudWatch Logs)"
  vpc_id      = data.aws_vpc.lambda_endpoints[0].id

  ingress {
    description     = "HTTPS from Lambda authorizer"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_authorizer[0].id]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc-endpoints"
  })
}

# ----------------------------------------------------------------------------
# VPC Interface Endpoint: Amazon Verified Permissions
# ----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "verifiedpermissions" {
  count = local.use_lambda_function ? 1 : 0

  vpc_id              = data.aws_vpc.lambda_endpoints[0].id
  service_name        = "com.amazonaws.${var.aws_region}.verifiedpermissions"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.lambda_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-verifiedpermissions"
  })
}

# ----------------------------------------------------------------------------
# VPC Interface Endpoint: CloudWatch Logs
# ----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  count = local.use_lambda_function ? 1 : 0

  vpc_id              = data.aws_vpc.lambda_endpoints[0].id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = var.lambda_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-endpoint-cloudwatch-logs"
  })
}
