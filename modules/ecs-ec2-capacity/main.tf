# Local Zone'da Fargate olmadigi icin ECS task'lari bu Auto Scaling Group'un
# EC2 instance'larinda calisir. Kapasiteyi ECS yonetir (managed scaling):
# yerlesemeyen task oldugunda instance ekler, bos instance'i bosaltip kapatir.
#
# awsvpc modunda her task kendi ENI'sini alir. ENI trunking kapali, bu yuzden
# bir instance'a (ENI sayisi - 1) task sigar: m7i.large'da 2.

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# AMI guncellemesi ve sorun giderme icin SSH yerine Session Manager.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-ecs-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name        = "${var.name}-ecs-instance-sg"
  description = "ECS container instances - no inbound, tasks have their own ENI"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-ecs-instance-sg" }
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.instance.id]

  # ECS_AWSVPC_BLOCK_IMDS: task'lar instance rolune erisemesin, yalnizca kendi
  # task rollerini kullansin.
  user_data = base64encode(<<-BASH
    #!/bin/bash
    cat >> /etc/ecs/ecs.config <<EOF
    ECS_CLUSTER=${var.cluster_name}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_AWSVPC_BLOCK_IMDS=true
    EOF
  BASH
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-ecs" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-ecs-root" })
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-ecs"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size

  # Managed termination protection icin sart: ASG task calisan bir instance'i
  # kendi basina kapatmasin, ECS once bosaltsin.
  protect_from_scale_in = true

  # Korumali instance'lar varken destroy'un takilmamasi icin (her olcum
  # turundan sonra ortam kapatiliyor).
  force_delete = true

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # Yeni AMI veya instance tipi launch template'e yazilinca instance'lar
  # sirayla yenilenir; ECS her birini kapatmadan once bosaltir.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      # Instance'lar scale-in korumali; varsayilan (Ignore) onlari hic yenilemez.
      scale_in_protected_instances = "Refresh"
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # Agent ECS API'ye instance rolunun policy'leriyle konusur. Destroy'da bu
  # attachment'lar servisle ayni anda silinirse agent task'larin durdugunu
  # bildiremez ve servis DRAINING'de kalir; ASG'ye (ve ondan capacity
  # provider'a, servise) baglayinca once servis, en son policy'ler gider.
  depends_on = [
    aws_iam_role_policy_attachment.ecs,
    aws_iam_role_policy_attachment.ssm,
  ]
}

resource "aws_ecs_capacity_provider" "this" {
  name = "${var.name}-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this.arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}
