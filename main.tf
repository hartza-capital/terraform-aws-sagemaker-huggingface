

# ------------------------------------------------------------------------------
# Local configurations
# ------------------------------------------------------------------------------

locals {
  framework_version = var.pytorch_version != null ? var.pytorch_version : var.tensorflow_version
  repository_name   = var.pytorch_version != null ? "huggingface-pytorch-inference" : "huggingface-tensorflow-inference"
  image_key         = "${local.framework_version}-cpu"
  pytorch_image_tag = {
    "1.7.1-cpu"  = "1.7.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
    "1.8.1-cpu"  = "1.8.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
    "1.9.1-cpu"  = "1.9.1-transformers${var.transformers_version}-cpu-py38-ubuntu20.04"
    "1.10.2-cpu" = "1.10.2-transformers${var.transformers_version}-cpu-py38-ubuntu20.04"
    "1.13.1-cpu" = "1.13.1-transformers${var.transformers_version}-cpu-py39-ubuntu20.04"
    "2.0.0-cpu"  = "2.0.0-transformers${var.transformers_version}-cpu-py310-ubuntu20.04"
    "2.1.0-cpu"  = "2.1.0-transformers${var.transformers_version}-cpu-py310-ubuntu22.04"
  }
  tensorflow_image_tag = {
    "2.4.1-cpu" = "2.4.1-transformers${var.transformers_version}-cpu-py37-ubuntu18.04"
    "2.5.1-cpu" = "2.5.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
  }
  sagemaker_endpoint_type = {
    real_time    = (var.async_config.s3_output_path == null && var.serverless_config.max_concurrency == null) ? true : false
    asynchronous = (var.async_config.s3_output_path != null && var.serverless_config.max_concurrency == null) ? true : false
    serverless   = (var.async_config.s3_output_path == null && var.serverless_config.max_concurrency != null) ? true : false
  }
}

# random lowercase string used for naming
resource "random_string" "resource_id" {
  length  = 8
  lower   = true
  special = false
  upper   = false
  numeric = false
}

# ------------------------------------------------------------------------------
# Container Image
# ------------------------------------------------------------------------------


data "aws_ecr_image" "deploy_image" {
  repository_name = local.repository_name
  image_tag       = var.pytorch_version != null ? local.pytorch_image_tag[local.image_key] : local.tensorflow_image_tag[local.image_key]
}

# ------------------------------------------------------------------------------
# Permission
# ------------------------------------------------------------------------------

resource "aws_iam_role" "new_role" {
  count = var.sagemaker_execution_role == null ? 1 : 0 # Creates IAM role if not provided
  name  = "${var.name_prefix}-sagemaker-execution-role-${random_string.resource_id.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      },
    ]
  })

  inline_policy {
    name = "terraform-inferences-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow",
          Action = [
            "cloudwatch:PutMetricData",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:CreateLogGroup",
            "logs:DescribeLogStreams",
            "s3:GetObject",
            "s3:PutObject",
            "s3:ListBucket",
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage"
          ],
          Resource = "*"
        }
      ]
    })

  }

  tags = var.tags
}

data "aws_iam_role" "get_role" {
  count = var.sagemaker_execution_role != null ? 1 : 0 # Creates IAM role if not provided
  name  = var.sagemaker_execution_role
}

locals {
  role_arn   = var.sagemaker_execution_role != null ? data.aws_iam_role.get_role[0].arn : aws_iam_role.new_role[0].arn
  model_slug = var.model_data != null ? "-${replace(reverse(split("/", replace(var.model_data, ".tar.gz", "")))[0], ".", "-")}" : ""
}

# ------------------------------------------------------------------------------
# SageMaker Model
# ------------------------------------------------------------------------------

resource "aws_sagemaker_model" "model_with_model_artifact" {
  count              = var.model_data != null && var.hf_model_id == null ? 1 : 0
  name               = "${var.name_prefix}-model-${random_string.resource_id.result}${local.model_slug}"
  execution_role_arn = local.role_arn
  tags               = var.tags

  primary_container {
    # CPU Image
    image          = data.aws_ecr_image.deploy_image.image_uri
    model_data_url = var.model_data
    environment = {
      HF_TASK = var.hf_task
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_sagemaker_model" "model_with_hub_model" {
  count              = var.model_data == null && var.hf_model_id != null ? 1 : 0
  name               = "${var.name_prefix}-model-${random_string.resource_id.result}${local.model_slug}"
  execution_role_arn = local.role_arn
  tags               = var.tags

  primary_container {
    image = data.aws_ecr_image.deploy_image.image_uri 
    environment = {
      HF_TASK           = var.hf_task
      HF_MODEL_ID       = var.hf_model_id
      HF_API_TOKEN      = var.hf_api_token
      HF_MODEL_REVISION = var.hf_model_revision
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  sagemaker_model = var.model_data != null && var.hf_model_id == null ? aws_sagemaker_model.model_with_model_artifact[0] : aws_sagemaker_model.model_with_hub_model[0]
}

# ------------------------------------------------------------------------------
# SageMaker Endpoint configuration
# ------------------------------------------------------------------------------

resource "aws_sagemaker_endpoint_configuration" "huggingface" {
  count = local.sagemaker_endpoint_type.real_time ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.resource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name           = "AllTraffic"
    model_name             = local.sagemaker_model.name
  }
}


resource "aws_sagemaker_endpoint_configuration" "huggingface_async" {
  count = local.sagemaker_endpoint_type.asynchronous ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.resource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name           = "AllTraffic"
    model_name             = local.sagemaker_model.name
  }
  async_inference_config {
    output_config {
      s3_output_path  = var.async_config.s3_output_path
      s3_failure_path = var.async_config.s3_failure_path
      kms_key_id      = var.async_config.kms_key_id
      notification_config {
        error_topic   = var.async_config.sns_error_topic
        success_topic = var.async_config.sns_success_topic
      }
    }
  }
}


resource "aws_sagemaker_endpoint_configuration" "huggingface_serverless" {
  count = local.sagemaker_endpoint_type.serverless ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.resource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name = "AllTraffic"
    model_name   = local.sagemaker_model.name

    serverless_config {
      max_concurrency   = var.serverless_config.max_concurrency
      memory_size_in_mb = var.serverless_config.memory_size_in_mb
    }
  }
}


locals {
  sagemaker_endpoint_config = (
    local.sagemaker_endpoint_type.real_time ?
    aws_sagemaker_endpoint_configuration.huggingface[0] : (
      local.sagemaker_endpoint_type.asynchronous ?
      aws_sagemaker_endpoint_configuration.huggingface_async[0] : (
        local.sagemaker_endpoint_type.serverless ?
        aws_sagemaker_endpoint_configuration.huggingface_serverless[0] : null
      )
    )
  )
}

# ------------------------------------------------------------------------------
# SageMaker Endpoint
# ------------------------------------------------------------------------------


resource "aws_sagemaker_endpoint" "huggingface" {
  name = "${var.name_prefix}-ep-${random_string.resource_id.result}"
  tags = var.tags

  endpoint_config_name = local.sagemaker_endpoint_config.name
}
