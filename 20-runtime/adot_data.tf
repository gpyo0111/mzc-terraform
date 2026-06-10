data "aws_ssm_parameter" "api_adot_config" {
  name = "/securevoice/dev/adot/api-config"
}

data "aws_ssm_parameter" "free_worker_adot_config" {
  name = "/securevoice/dev/adot/free-worker-config"
}

data "aws_ssm_parameter" "paid_worker_adot_config" {
  name = "/securevoice/dev/adot/paid-worker-config"
}