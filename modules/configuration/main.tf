terraform {
  backend "s3" {}
}

provider "aws" {
  region  = var.env.region
}

data "aws_caller_identity" "current" {}

resource "aws_dynamodb_table" "confd" {
  name         = "${var.tags.environment}-dynamodb"
  billing_mode = local.configuration.billing_mode
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  tags = var.tags
}


resource "aws_kms_key" "confd" {
  description             = "KMS key for ${var.tags.environment}-dynamodb"
  key_usage               = "ENCRYPT_DECRYPT"
  deletion_window_in_days = local.configuration.kms_key_deletion_window_in_days
  is_enabled              = "true"
  enable_key_rotation     = local.configuration.kms_key_enable_key_rotation
  policy                  = data.aws_iam_policy_document.aurora_policy.json

  tags = merge( var.tags, tomap({ "Name" = format("%s-confd", var.tags.environment) }) )
}

resource "aws_kms_alias" "confd" {
  name          = "alias/${var.tags.environment}-confd"
  target_key_id = aws_kms_key.confd.key_id
}



data "aws_iam_policy_document" "aurora_policy" {
  statement {
    sid       = "Enable IAM User Permissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.env.aws_account}:root"]
    }
  }
}

/*

data "aws_iam_policy_document" "aurora_policy" {
  statement {
    sid       = "Enable IAM User Permissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.env.account_id}:root"]
    }
  }
  statement {
    sid    = "Allow use of the key"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:List*",
      "kms:CreateGrant"
    ]
    resources = ["*"]
    principals {
      type = "AWS"
      identifiers = [ 
        "arn:aws:iam::${var.env.account_id}:role/${var.tags.environment}-backup-role",
        "arn:aws:iam::${var.env.account_id}:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup",
        "arn:aws:iam::${var.env.bunker_acc_id}:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup",
        ]
    }
  }
}
*/


resource "aws_iam_policy" "allow_confd" {
  name        = "${var.tags.environment}-confd-sync"
  description = ""

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": "${aws_dynamodb_table.confd.arn}"
    }
  ]
}
EOF
}

// Do confd-sync (Insert/Update records in DynamoDB; Reads config.properties/secret.properties defined under <environment_namr> folder)
data "template_file" "confd_sync" {
  template = file("${path.module}/templates/confd-sync.sh")

  vars = {
    region           = var.env.region
    confd_key_arn    = aws_kms_key.confd.arn
    confd_table_name = aws_dynamodb_table.confd.id
    environment      = var.tags.environment
    account_id       = data.aws_caller_identity.current.account_id
  }
}

/*
data "template_file" "confd_sync_serv" {
  template = file("${path.module}/templates/confd-sync-services.sh")

  vars = {
    region           = var.env.region
    confd_key_arn    = aws_kms_key.confd.arn
    confd_table_name = aws_dynamodb_table.confd.id
    environment      = var.tags.environment
    account_id       = data.aws_caller_identity.current.account_id
  }
}
*/

resource "null_resource" "confd_config_values" {
  triggers = {
    table_arn   = aws_dynamodb_table.confd.arn
    config_hash = filemd5("config.properties")
    secret_hash = filemd5("secret.properties")
    sync_hash   = md5(data.template_file.confd_sync.rendered)
    //before      = null_resource.confd_cluster_values_services.id
  }

  provisioner "local-exec" {
    command = data.template_file.confd_sync.rendered
  }
}
/*

resource "null_resource" "confd_cluster_values_services" {
  //depends_on = ["null_resource.confd_cluster_values_auth"]

  triggers = {
    table_arn   = aws_dynamodb_table.confd.arn
    config_hash = filemd5("services-config.properties")
    secret_hash = filemd5("services-secret.properties")
    sync_hash   = md5(data.template_file.confd_sync_serv.rendered)cd en 
  }

  provisioner "local-exec" {
    command = data.template_file.confd_sync_serv.rendered
  }
}

*/