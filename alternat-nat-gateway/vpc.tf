provider "aws" {
  region = "us-east-1"
  default_tags { tags = { Project = "alternat-demo" } }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = "alternat-demo"
  cidr            = "10.0.0.0/16"
  azs             = ["us-east-1a"]
  public_subnets  = ["10.0.0.0/24"]
  private_subnets = ["10.0.1.0/24"]
}
