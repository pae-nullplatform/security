terraform {
  backend "s3" {
    bucket  = "tf-state-66b27a8f71ff518f"
    key     = "security/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
    profile = "providers-test"
  }
}
