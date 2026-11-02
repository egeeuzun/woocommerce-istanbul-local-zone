# Residency Guard'in (residency-guard/) AWS tarafi:
#
#   - Salt okunur IAM rolu: guard bu rolle calisir. Kaynaklari listeler, log
#     gruplarindan ornek satir okur, Athena sorgusu calistirir; hicbir seyi
#     degistirmez (Athena sonuclarini yazmak disinda).
#   - Olcum penceresi (capture_enabled): LZ VPC'sinin Flow Logs'u ve Route 53
#     Resolver DNS sorgu loglari. Ikisi de IP adresi icerir; yalnizca denetim
#     sirasinda acin. Bucket'taki her sey retention_days sonra silinir.
#   - Athena: iki log icin partition projection'li tablolar ve sonuclarin
#     yazildigi workgroup. Kapaliyken de durur; ucretsizdir.
#
# Bucket parent region'da (Frankfurt). Denetim verisinin konumu rapora yazilir
# (RG-009); LZ'de normal bir S3 bucket'i yok.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  flow_logs_prefix = "flow-logs"
  dns_logs_prefix  = "dns-logs"
  athena_prefix    = "athena-results"

  # Glue adlarinda tire olmaz
  glue_database = replace("${var.name}_residency", "-", "_")

  trusted_principal_arns = length(var.trusted_principal_arns) > 0 ? var.trusted_principal_arns : [
    "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root",
  ]
}

# --- Denetim verisi bucket'i --------------------------------------------------

resource "aws_s3_bucket" "audit" {
  bucket_prefix = "${var.name}-residency-"

  # Icindekiler kisa omurlu log ve sorgu sonucu; ortam silinirken engel olmasin
  force_destroy = true

  tags = merge(var.tags, { Name = "${var.name}-residency-audit" })
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expire-audit-data"
    status = "Enabled"

    filter {}

    expiration {
      days = var.retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Flow Logs ve Resolver query logging ayni servis principal'iyla yazar. Bu
# politika olmasa da AWS kendisi ekler; burada olunca Terraform'un disinda
# degisiklik olmaz ve yalnizca bu hesabin loglari kabul edilir.
data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid     = "LogDeliveryWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.audit.arn}/${local.flow_logs_prefix}/AWSLogs/${local.account_id}/*",
      "${aws_s3_bucket.audit.arn}/${local.dns_logs_prefix}/AWSLogs/${local.account_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "LogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.audit]
}

# --- Olcum penceresi: Flow Logs ve DNS sorgu loglari --------------------------

# Parquet ve saatlik klasorler: Athena yalnizca sorgulanan saatleri okur.
# Ozel format, LZ'yi ve trafigin yolunu ayirt eden v3-v5 alanlarini da tasir.
resource "aws_flow_log" "vpc" {
  count = var.capture_enabled ? 1 : 0

  vpc_id                   = var.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = "${aws_s3_bucket.audit.arn}/${local.flow_logs_prefix}/"
  max_aggregation_interval = 60

  log_format = join(" ", [for f in local.flow_log_fields : "$${${f}}"])

  destination_options {
    file_format        = "parquet"
    per_hour_partition = true
  }

  tags = merge(var.tags, { Name = "${var.name}-residency-flow-log" })

  depends_on = [aws_s3_bucket_policy.audit]
}

locals {
  flow_log_fields = [
    "version", "account-id", "interface-id", "srcaddr", "dstaddr", "srcport",
    "dstport", "protocol", "packets", "bytes", "start", "end", "action",
    "log-status", "vpc-id", "subnet-id", "instance-id", "tcp-flags", "type",
    "pkt-srcaddr", "pkt-dstaddr", "region", "az-id", "sublocation-type",
    "sublocation-id", "pkt-src-aws-service", "pkt-dst-aws-service",
    "flow-direction", "traffic-path",
  ]
}

resource "aws_route53_resolver_query_log_config" "dns" {
  count = var.capture_enabled ? 1 : 0

  name            = "${var.name}-residency-dns"
  destination_arn = "${aws_s3_bucket.audit.arn}/${local.dns_logs_prefix}"

  tags = merge(var.tags, { Name = "${var.name}-residency-dns" })

  depends_on = [aws_s3_bucket_policy.audit]
}

resource "aws_route53_resolver_query_log_config_association" "dns" {
  count = var.capture_enabled ? 1 : 0

  resolver_query_log_config_id = aws_route53_resolver_query_log_config.dns[0].id
  resource_id                  = var.vpc_id
}

# --- Athena -------------------------------------------------------------------

resource "aws_glue_catalog_database" "this" {
  name        = local.glue_database
  description = "Residency Guard: ${var.name} VPC Flow Logs ve DNS sorgu loglari"
}

resource "aws_glue_catalog_table" "flow_logs" {
  name          = "flow_logs"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                    = "TRUE"
    "projection.enabled"        = "true"
    "projection.date.type"      = "date"
    "projection.date.range"     = "2026/01/01,NOW"
    "projection.date.format"    = "yyyy/MM/dd"
    "projection.hour.type"      = "integer"
    "projection.hour.range"     = "0,23"
    "projection.hour.digits"    = "2"
    "storage.location.template" = "s3://${aws_s3_bucket.audit.id}/${local.flow_logs_prefix}/AWSLogs/${local.account_id}/vpcflowlogs/${local.region}/$${date}/$${hour}/"
  }

  partition_keys {
    name = "date"
    type = "string"
  }

  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.audit.id}/${local.flow_logs_prefix}/AWSLogs/${local.account_id}/vpcflowlogs/${local.region}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.flow_log_columns
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

locals {
  # Parquet'te alan adlarindaki tireler alt cizgi olur
  flow_log_columns = {
    version             = "int"
    account_id          = "string"
    interface_id        = "string"
    srcaddr             = "string"
    dstaddr             = "string"
    srcport             = "int"
    dstport             = "int"
    protocol            = "bigint"
    packets             = "bigint"
    bytes               = "bigint"
    start               = "bigint"
    end                 = "bigint"
    action              = "string"
    log_status          = "string"
    vpc_id              = "string"
    subnet_id           = "string"
    instance_id         = "string"
    tcp_flags           = "int"
    type                = "string"
    pkt_srcaddr         = "string"
    pkt_dstaddr         = "string"
    region              = "string"
    az_id               = "string"
    sublocation_type    = "string"
    sublocation_id      = "string"
    pkt_src_aws_service = "string"
    pkt_dst_aws_service = "string"
    flow_direction      = "string"
    traffic_path        = "int"
  }
}

resource "aws_glue_catalog_table" "dns_logs" {
  name          = "dns_logs"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                    = "TRUE"
    "projection.enabled"        = "true"
    "projection.date.type"      = "date"
    "projection.date.range"     = "2026/01/01,NOW"
    "projection.date.format"    = "yyyy/MM/dd"
    "storage.location.template" = "s3://${aws_s3_bucket.audit.id}/${local.dns_logs_prefix}/AWSLogs/${local.account_id}/vpcdnsquerylogs/${var.vpc_id}/$${date}/"
  }

  partition_keys {
    name = "date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.audit.id}/${local.dns_logs_prefix}/AWSLogs/${local.account_id}/vpcdnsquerylogs/${var.vpc_id}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "version"
      type = "string"
    }
    columns {
      name = "account_id"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
    columns {
      name = "vpc_id"
      type = "string"
    }
    columns {
      name = "query_timestamp"
      type = "string"
    }
    columns {
      name = "query_name"
      type = "string"
    }
    columns {
      name = "query_type"
      type = "string"
    }
    columns {
      name = "rcode"
      type = "string"
    }
    columns {
      name = "srcaddr"
      type = "string"
    }
    columns {
      name = "srcids"
      type = "struct<instance:string,resolver_endpoint:string>"
    }
  }
}

resource "aws_athena_workgroup" "this" {
  name          = "${var.name}-residency-guard"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.audit.id}/${local.athena_prefix}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = var.tags
}

# --- Salt okunur denetim rolu -------------------------------------------------

data "aws_iam_policy_document" "guard_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "guard" {
  name                 = "${var.name}-residency-guard"
  description          = "Residency Guard: salt okunur veri yerelligi denetimi"
  assume_role_policy   = data.aws_iam_policy_document.guard_assume.json
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "guard" {
  # Envanter: etiketli kaynaklar ve konumlari, tum bolgelerde
  statement {
    sid = "Inventory"
    actions = [
      "tag:GetResources",
      "ec2:DescribeRegions",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeNatGateways",
      "ec2:DescribeRouteTables",
      "ec2:DescribeFlowLogs",
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:DescribeDBSnapshots",
      "rds:DescribeDBClusterSnapshots",
      "rds:ListTagsForResource",
      "elasticache:DescribeCacheClusters",
      "elasticache:DescribeReplicationGroups",
      "elasticache:DescribeSnapshots",
      "elasticfilesystem:DescribeFileSystems",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
      "backup:ListBackupVaults",
      "backup:ListRecoveryPointsByBackupVault",
      "backup:ListTags",
      "dlm:GetLifecyclePolicies",
      "dlm:GetLifecyclePolicy",
      "ecs:ListClusters",
      "ecs:DescribeClusters",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
      "autoscaling:DescribeAutoScalingGroups",
      "route53resolver:ListResolverQueryLogConfigs",
      "route53resolver:ListResolverQueryLogConfigAssociations",
    ]
    resources = ["*"]
  }

  # Etiketsiz kisisel veri: log gruplarindan ornek satir. Guard eslesen
  # degerleri rapora yazmaz, yalnizca sayar.
  statement {
    sid = "LogSampling"
    actions = [
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:FilterLogEvents",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AthenaQuery"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.this.arn]
  }

  statement {
    sid = "GlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetPartitions",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${local.region}:${local.account_id}:catalog",
      aws_glue_catalog_database.this.arn,
      "arn:${data.aws_partition.current.partition}:glue:${local.region}:${local.account_id}:table/${aws_glue_catalog_database.this.name}/*",
    ]
  }

  statement {
    sid       = "AuditBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.audit.arn]
  }

  statement {
    sid     = "AuditBucketRead"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.audit.arn}/${local.flow_logs_prefix}/*",
      "${aws_s3_bucket.audit.arn}/${local.dns_logs_prefix}/*",
      "${aws_s3_bucket.audit.arn}/${local.athena_prefix}/*",
    ]
  }

  # Guard'in yazabildigi tek yer: kendi Athena sonuclari
  statement {
    sid       = "AthenaResultsWrite"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.audit.arn}/${local.athena_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "guard" {
  name   = "${var.name}-residency-guard"
  role   = aws_iam_role.guard.id
  policy = data.aws_iam_policy_document.guard.json
}
