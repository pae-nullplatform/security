# ============================================================================
# Amazon Verified Permissions - Smoke Test
# ============================================================================
# Este módulo implementa autorización de endpoints usando Amazon Verified
# Permissions con un Pod gRPC nativo (sin Lambda).
# ============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Versión semver del authorizer (PEP 440 compatible)
  authorizer_version = trimspace(file("${path.module}/authorizer/VERSION"))

  common_tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "avp-authorization"
  })
}

# ============================================================================
# Data Sources
# ============================================================================

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "current" {
  name = var.eks_cluster_name
}

# ============================================================================
# Amazon Verified Permissions - Policy Store
# ============================================================================

resource "aws_verifiedpermissions_policy_store" "main" {
  description = "Policy store for ${local.name_prefix} API authorization"

  validation_settings {
    mode = "STRICT"
  }
}

# ============================================================================
# Schema Definition
# ============================================================================

resource "aws_verifiedpermissions_schema" "main" {
  policy_store_id = aws_verifiedpermissions_policy_store.main.id

  definition {
    value = file("${path.module}/schema.json")
  }
}

# ============================================================================
# Identity Source (JWT/OIDC) - Commented out for smoke test
# ============================================================================
# Note: For smoke test, JWT validation is handled locally in the authorizer.
# In production, configure a real OIDC provider here.
#
# resource "aws_verifiedpermissions_identity_source" "jwt" {
#   policy_store_id = aws_verifiedpermissions_policy_store.main.id
#   ...
# }

# ============================================================================
# Policies - Cargadas desde archivos Cedar
# ============================================================================

resource "aws_verifiedpermissions_policy" "allow_authenticated_read" {
  policy_store_id = aws_verifiedpermissions_policy_store.main.id

  definition {
    static {
      description = "Allow authenticated users to read public endpoints"
      statement   = file("${path.module}/policies/allow_authenticated_read.cedar")
    }
  }

  depends_on = [aws_verifiedpermissions_schema.main]
}

resource "aws_verifiedpermissions_policy" "allow_smoke_access" {
  policy_store_id = aws_verifiedpermissions_policy_store.main.id

  definition {
    static {
      description = "Allow users with smoke-testers group to access /smoke endpoints"
      statement   = file("${path.module}/policies/allow_smoke_access.cedar")
    }
  }

  depends_on = [aws_verifiedpermissions_schema.main]
}

resource "aws_verifiedpermissions_policy" "deny_expired_tokens" {
  policy_store_id = aws_verifiedpermissions_policy_store.main.id

  definition {
    static {
      description = "Deny access for expired tokens"
      statement   = file("${path.module}/policies/deny_expired_tokens.cedar")
    }
  }

  depends_on = [aws_verifiedpermissions_schema.main]
}

# ============================================================================
# IAM Role for Pod (IRSA - IAM Roles for Service Accounts)
# ============================================================================

resource "aws_iam_role" "avp_authorizer" {
  name = "${local.name_prefix}-avp-authorizer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.current.identity[0].oidc[0].issuer, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.current.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:${var.kubernetes_namespace}:avp-ext-authz"
            "${replace(data.aws_eks_cluster.current.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "avp_authorizer" {
  name = "${local.name_prefix}-avp-access"
  role = aws_iam_role.avp_authorizer.id

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

# ============================================================================
# ECR Repository for Authorizer Image
# ============================================================================

resource "aws_ecr_repository" "authorizer" {
  name                 = "${local.name_prefix}-avp-authorizer"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Permite eliminar el repo incluso con imágenes

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "authorizer" {
  repository = aws_ecr_repository.authorizer.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
      # TODO: Habilitar cuando se defina el proceso de actualización de imágenes
      # {
      #   rulePriority = 2
      #   description  = "Keep last 10 tagged images"
      #   selection = {
      #     tagStatus     = "tagged"
      #     tagPrefixList = ["v", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
      #     countType     = "imageCountMoreThan"
      #     countNumber   = 10
      #   }
      #   action = {
      #     type = "expire"
      #   }
      # }
    ]
  })
}

# ============================================================================
# Docker Image Build & Push
# ============================================================================

resource "docker_image" "authorizer" {
  name = "${aws_ecr_repository.authorizer.repository_url}:${local.authorizer_version}"

  build {
    context    = "${path.module}/authorizer"
    dockerfile = "Dockerfile"
    label = {
      "org.opencontainers.image.version" = local.authorizer_version
      "org.opencontainers.image.source"  = "terraform"
    }
  }

  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset("${path.module}/authorizer", "**") : filesha1("${path.module}/authorizer/${f}")]))
    version  = local.authorizer_version
  }
}

resource "docker_registry_image" "authorizer" {
  name          = docker_image.authorizer.name
  keep_remotely = false # Elimina la imagen del registry en destroy

  depends_on = [aws_ecr_repository.authorizer]
}
