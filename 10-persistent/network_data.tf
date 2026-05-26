data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = "../00-network/terraform.tfstate"
  }
}