module "alternat" {
  source  = "chime/alternat/aws"
  version = "0.10.4"

  vpc_id = module.vpc.vpc_id
  vpc_az_maps = [{
    az                 = "us-east-1a"
    public_subnet_id   = module.vpc.public_subnets[0]
    private_subnet_ids = module.vpc.private_subnets
    route_table_ids    = module.vpc.private_route_table_ids
  }]
  ingress_security_group_cidr_blocks = ["10.0.1.0/24"]

  nat_instance_type   = "t4g.small" # default is c6gn.8xlarge!
  lambda_package_type = "Zip"
  lambda_zip_path     = "${path.root}/lambda.zip"
  lambda_has_ipv6     = false
}
