#
# output "cluster_id" { value = "${module.rds.cluster_id}" }
# output "cluster_arn" { value = "${module.rds.cluster_arn}" }
# output "cluster_writer_endpoint" { value = "${module.rds.cluster_writer_endpoint}" }
# output "cluster_reader_endpoint" { value = "${module.rds.cluster_reader_endpoint}" }
# output "instance_ids" { value = "${module.rds.instance_ids}" }
# output "endpoints" { value = "${module.rds.endpoints}" }
output "db_security_group_id" {
  value = aws_security_group.db.id 
}

/*output "aurora_final_snapshot_identifier" {
  value = aws_rds_cluster.aurora.final_snapshot_identifier.name
}*/