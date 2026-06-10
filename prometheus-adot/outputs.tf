output "amp_workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  value = aws_prometheus_workspace.this.arn
}

output "amp_prometheus_endpoint" {
  value = aws_prometheus_workspace.this.prometheus_endpoint
}

output "amp_remote_write_endpoint" {
  value = local.amp_remote_write_endpoint
}

output "api_adot_config_parameter_arn" {
  value = aws_ssm_parameter.api_adot_config.arn
}

output "free_worker_adot_config_parameter_arn" {
  value = aws_ssm_parameter.free_worker_adot_config.arn
}

output "paid_worker_adot_config_parameter_arn" {
  value = aws_ssm_parameter.paid_worker_adot_config.arn
}

output "adot_ssm_read_policy_arn" {
  value = aws_iam_policy.adot_ssm_read.arn
}