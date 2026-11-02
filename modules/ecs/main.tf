locals {
  # null = Fargate. Dolu ise servis bu EC2 capacity provider'inda calisir
  # (Local Zone'da Fargate yok).
  on_ec2 = var.capacity_provider_name != null

  wp_config_extra = <<-PHP
    if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
        $_SERVER['HTTPS'] = 'on';
    }
    define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL | MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT);
  PHP

  media_environment = var.media_bucket_enabled ? [
    { name = "WP_S3_BUCKET", value = var.media_bucket_name },
    { name = "WP_S3_REGION", value = var.region },
    { name = "WP_S3_DELIVERY_DOMAIN", value = var.media_base_url },
    { name = "WP_S3_OBJECT_PREFIX", value = "wp-content/uploads/" },
    { name = "WP_S3_REMOVE_LOCAL", value = var.media_remove_local ? "1" : "0" },
  ] : []

  uploads_volumes = var.efs_enabled ? [
    { name = "wp-data", access_point_id = var.efs_access_point_id, path = "/var/www/html/wp-content/uploads" },
  ] : []

  code_volumes = var.shared_code_enabled ? [
    { name = "wp-plugins", access_point_id = var.efs_plugins_access_point_id, path = "/var/www/html/wp-content/plugins" },
    { name = "wp-themes", access_point_id = var.efs_themes_access_point_id, path = "/var/www/html/wp-content/themes" },
  ] : []

  efs_volumes = concat(local.uploads_volumes, local.code_volumes)

  # Imaj acilista WordPress'i kurar ve seed'i calistirir (wordpress-shop-demo,
  # docker/auto-seed.php); yalnizca bir task calistirir, digerleri atlar.
  auto_seed_environment = var.auto_seed ? [
    { name = "SHOP_AUTO_SEED", value = "1" },
    { name = "WORDPRESS_ADMIN_USER", value = var.admin_username },
    { name = "WORDPRESS_ADMIN_EMAIL", value = var.admin_email },
    # Secret'lar task acilirken okunur; SSM'deki parola degisince task'lar
    # kendiliginden yenilenmez. Surum task tanimina girince yenilenir.
    { name = "WORDPRESS_ADMIN_PASSWORD_VERSION", value = tostring(var.admin_password_version) },
  ] : []

  auto_seed_secrets = var.auto_seed ? [
    { name = "WORDPRESS_ADMIN_PASSWORD", valueFrom = var.admin_password_ssm_arn },
  ] : []

  efs_access_point_arns = concat(
    var.efs_enabled ? [var.efs_access_point_arn] : [],
    var.shared_code_enabled ? [var.efs_plugins_access_point_arn, var.efs_themes_access_point_arn] : [],
  )
}

resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.autoscaling_max
  min_capacity       = var.autoscaling_min
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.wordpress.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}-wordpress"
  retention_in_days = 30

  tags = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      execute_command_configuration {
        logging = "OVERRIDE"

        log_configuration {
          cloud_watch_log_group_name = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }
}

resource "aws_cloudwatch_log_group" "exec" {
  count             = var.enable_execute_command ? 1 : 0
  name              = "/ecs/${var.name}-exec"
  retention_in_days = 30

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = local.on_ec2 ? [var.capacity_provider_name] : ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = local.on_ec2 ? var.capacity_provider_name : "FARGATE"
    weight            = 1
  }
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_ssm" {
  name = "${var.name}-ssm-read"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = concat([var.db_password_ssm_arn], values(var.wp_salt_ssm_arns), var.auto_seed ? [var.admin_password_ssm_arn] : [])
    }]
  })
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "task_efs" {
  count = var.efs_enabled ? 1 : 0
  name  = "${var.name}-efs-access"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ]
      Resource = var.efs_arn
      Condition = {
        StringEquals = {
          "elasticfilesystem:AccessPointArn" = local.efs_access_point_arns
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "task_media_bucket" {
  count = var.media_bucket_enabled ? 1 : 0
  name  = "${var.name}-media-bucket-access"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketAcl",
          "s3:GetBucketPolicyStatus",
        ]
        Resource = var.media_bucket_arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${var.media_bucket_arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "task_exec_command" {
  count = var.enable_execute_command ? 1 : 0
  name  = "${var.name}-ecs-exec"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.exec[0].arn}:*"
      },
    ]
  })
}

resource "aws_ecs_service" "wordpress" {
  name                   = "${var.name}-wordpress"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.wordpress.arn
  desired_count          = var.desired_count
  launch_type            = local.on_ec2 ? null : "FARGATE"
  enable_execute_command = var.enable_execute_command

  dynamic "capacity_provider_strategy" {
    for_each = local.on_ec2 ? [1] : []
    content {
      capacity_provider = var.capacity_provider_name
      weight            = 1
    }
  }

  # EC2'de task'lar once farkli instance'lara dagitilir; tek instance
  # dusse bile servis ayakta kalir.
  dynamic "ordered_placement_strategy" {
    for_each = local.on_ec2 ? [1] : []
    content {
      type  = "spread"
      field = "instanceId"
    }
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  # Local Zone tek lokasyon; dengelenecek ikinci bir zone yok.
  availability_zone_rebalancing = local.on_ec2 ? "DISABLED" : "ENABLED"

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "wordpress"
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 120

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # task_definition izlenir: Terraform'daki degisiklikler (secret, ortam
  # degiskeni) ancak boyle servise ulasir. CodePipeline'in ECS deploy'u
  # servisin o anki revizyonunu kopyalayip yalnizca imaji degistirdigi icin
  # ikisi birbirini ezmez; sonraki apply servisi imaji ayni olan :latest
  # revizyonuna geri alir.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

resource "aws_ecs_task_definition" "wordpress" {
  family                   = "${var.name}-wordpress"
  requires_compatibilities = [local.on_ec2 ? "EC2" : "FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  lifecycle {
    precondition {
      condition     = var.efs_enabled || !var.shared_code_enabled
      error_message = "Panelden eklenti/tema kurulumu (shared_code_enabled) EFS ister; aksi halde kurulan dosyalar tek task'ta kalir ve deploy'da kaybolur."
    }

    precondition {
      condition     = !var.auto_seed || var.admin_password_ssm_arn != ""
      error_message = "auto_seed yonetici parolasini (admin_password_ssm_arn) ister."
    }

    precondition {
      condition     = var.efs_enabled || var.media_bucket_enabled
      error_message = "EFS kapaliyken medya S3'e offload edilmeli (media_bucket_enabled); aksi halde yuklenen dosyalar task yeniden basladiginda kaybolur."
    }
  }

  container_definitions = jsonencode([
    {
      name      = "wordpress"
      image     = var.container_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = concat([
        { name = "WORDPRESS_DB_HOST", value = var.db_host },
        { name = "WORDPRESS_DB_NAME", value = var.db_name },
        { name = "WORDPRESS_DB_USER", value = var.db_username },
        { name = "MEMCACHED_HOST", value = var.memcached_endpoint },
        { name = "WP_HOME", value = var.wp_home },
        { name = "WORDPRESS_DISALLOW_FILE_MODS", value = var.shared_code_enabled ? "0" : "1" },
        { name = "WORDPRESS_CONFIG_EXTRA", value = local.wp_config_extra }
      ], local.media_environment, local.auto_seed_environment)

      secrets = concat([
        { name = "WORDPRESS_DB_PASSWORD", valueFrom = var.db_password_ssm_arn }
        ], [
        for k, arn in var.wp_salt_ssm_arns : { name = "WORDPRESS_${k}", valueFrom = arn }
      ], local.auto_seed_secrets)

      mountPoints = [
        for v in local.efs_volumes : {
          sourceVolume  = v.name
          containerPath = v.path
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "wordpress"
        }
      }
    }
  ])

  dynamic "volume" {
    for_each = local.efs_volumes

    content {
      name = volume.value.name

      efs_volume_configuration {
        file_system_id     = var.efs_id
        transit_encryption = "ENABLED"

        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }
}
