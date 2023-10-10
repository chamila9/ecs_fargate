output "table_arn" {
  value = aws_dynamodb_table.confd.arn
}

output "table_name" {
  value = aws_dynamodb_table.confd.id
}

output "key_arn" {
  value = aws_kms_key.confd.arn
}

output "key_id" {
  value = aws_kms_key.confd.id
}

output "policy" {
  value = aws_iam_policy.allow_confd.arn
}

output "config_hash" {
  value = md5(
    format("%s%s", file("config.properties"), file("secret.properties"))
  )
}
