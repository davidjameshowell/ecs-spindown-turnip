data "aws_caller_identity" "current" {}

locals {
    region = "us-east-1"
}

module "base-network" {
  source                                      = "cn-terraform/networking/aws"
  version                                     = "2.0.12"
  name_prefix                                 = "djhecstest"
  vpc_cidr_block                              = "192.168.0.0/16"
  availability_zones                          = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  public_subnets_cidrs_per_availability_zone  = ["192.168.0.0/19", "192.168.32.0/19", "192.168.64.0/19", "192.168.96.0/19"]
  private_subnets_cidrs_per_availability_zone = ["192.168.128.0/19", "192.168.160.0/19", "192.168.192.0/19", "192.168.224.0/19"]
}

module "ecs_module" {
  source              = "github.com/cn-terraform/terraform-aws-ecs-fargate.git?ref=2.0.27"
  name_prefix         = "djh-1635131276"
  vpc_id              = module.base-network.vpc_id
  container_image     = "nginxdemos/hello:latest"
  container_name      = "test"
  public_subnets_ids  = module.base-network.public_subnets_ids
  private_subnets_ids = module.base-network.private_subnets_ids

  enable_autoscaling = false
  lb_http_ports = {
    "default_http" : {
      "listener_port" : 8080,
      "target_group_port" : 80
    }
  }
  lb_https_ports = {}
  # Short deregistration for delay
  lb_deregistration_delay = 15
}

module "ecs_lambda_turnip_function" {
  source = "terraform-aws-modules/lambda/aws"

  function_name = "ecs-lambda-turnip"
  description   = "ECS function to turn up "
  handler       = "main.lambda_handler"
  runtime       = "python3.9"
  publish       = true

  source_path = "./lambda-src/ecs-lambda"
  attach_policy = true
  policy        = aws_iam_policy.ecs_lambda_turnip_policy.arn

  allowed_triggers = {
    APIGatewayAny = {
      service    = "apigateway"
      source_arn = module.ecs_turnip_api_gateway.apigatewayv2_api_arn
    }
  }

  tags = {
    Name = "ecs-lambda-turnip"
  }
}

data "aws_iam_policy_document" "ecs_lambda_turnip_policy_doc" {
  statement {
    sid = "ECSTurnipPerm"

    actions = [
        "ecs:ListAttributes",
        "ecs:DescribeTaskSets",
        "ecs:DescribeTaskDefinition",
        "ecs:ListServices",
        "ecs:UpdateService",
        "ecs:DescribeCapacityProviders",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeListeners",
        "ecs:ListTasks",
        "ecs:DescribeServices",
        "elasticloadbalancing:DescribeListenerCertificates",
        "ecs:DescribeContainerInstances",
        "ecs:DescribeTasks",
        "ecs:ListTaskDefinitions",
        "ecs:ListClusters",
        "elasticloadbalancing:DescribeSSLPolicies",
        "elasticloadbalancing:DescribeTags",
        "ecs:DescribeClusters",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "ecs:ListAccountSettings",
        "ecs:ListTagsForResource",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "ecs:ListTaskDefinitionFamilies",
        "elasticloadbalancing:DescribeAccountLimits",
        "elasticloadbalancing:DescribeTargetHealth",
        "route53:*",
        "elasticloadbalancing:DescribeTargetGroups",
        "ecs:ListContainerInstances",
        "elasticloadbalancing:DescribeRules"
    ]

    resources = [
      "*",
    ]
  }
}

resource "aws_iam_policy" "ecs_lambda_turnip_policy" {
  name   = "ECSLambdaTurnip"
  path   = "/"
  policy = data.aws_iam_policy_document.ecs_lambda_turnip_policy_doc.json
}

module "ecs_turnip_api_gateway" {
  source = "terraform-aws-modules/apigateway-v2/aws"
  version = "1.4.0"

  name          = "ecs-turnip-api"
  description   = "ECS Turnip API to turn up ECS services from inactivity"
  protocol_type = "HTTP"
  create_api_domain_name = false

  # Routes and integrations
  integrations = {
    "$default" = {
      lambda_arn = module.ecs_lambda_turnip_function.lambda_function_invoke_arn
      payload_format_version = "2.0"
      timeout_milliseconds   = 12000
    }
  }

  tags = {
    Name = "ecs-turnip-api"
  }
}

resource "aws_apigatewayv2_integration" "ecs_api_default_get_integration" {
    api_id                 = module.ecs_turnip_api_gateway.apigatewayv2_api_id
    connection_type        = "INTERNET"
    integration_method     = "POST"
    integration_type       = "AWS_PROXY"
    integration_uri        = module.ecs_lambda_turnip_function.lambda_function_invoke_arn
    payload_format_version = "2.0"
    request_parameters     = {}
    request_templates      = {}
    timeout_milliseconds   = 12000
}

resource "aws_apigatewayv2_route" "ecs_api_default_get_route" {
    api_id             = module.ecs_turnip_api_gateway.apigatewayv2_api_id
    api_key_required   = false
    authorization_type = "NONE"
    route_key          = "GET /"
    target             = "integrations/${aws_apigatewayv2_integration.ecs_api_default_get_integration.id}"
}

module "metric_alarms" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarms-by-multiple-dimensions"
  version = "~> 2.0"

  alarm_name          = "preview-environment-no-activity-"
  alarm_description   = "Requests to preview environment are 0; spin down to save money"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 10
  period              = 60
  unit                = "Milliseconds"

  namespace   = "AWS/Lambda"
  metric_name = "Duration"
  statistic   = "Maximum"

  dimensions = {
    "lambda1" = {
      FunctionName = "index"
    },
    "lambda2" = {
      FunctionName = "signup"
    },
  }

  alarm_actions = ["arn:aws:sns:eu-west-1:835367859852:my-sns-queue"]
}