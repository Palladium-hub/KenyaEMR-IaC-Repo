terraform {
  backend "s3" {
    bucket         = "kilifi-wal-archive-prod"
    key            = "terraform/infrastructure/terraform.tfstate"
    region         = "af-south-1"
    encrypt        = true
  }
}