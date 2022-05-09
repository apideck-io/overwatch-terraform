data "aws_rds_engine_version" "postgresql" {
  engine  = "aurora-postgresql"
  version = "13.6"
}

resource "aws_db_parameter_group" "postgresql13" {
  name        = "${var.deployment_name}-aurora-db-postgres13-parameter-group"
  family      = "aurora-postgresql13"
  description = "${var.deployment_name}-aurora-db-postgres13-parameter-group"
}

resource "aws_rds_cluster_parameter_group" "postgresql13" {
  name        = "${var.deployment_name}-aurora-postgres13-cluster-parameter-group"
  family      = "aurora-postgresql13"
  description = "${var.deployment_name}-aurora-postgres13-cluster-parameter-group"
}

module "rds_cluster" {
  source = "terraform-aws-modules/rds-aurora/aws"

  name              = var.deployment_name
  database_name     = "hammerhead_production"
  engine            = data.aws_rds_engine_version.postgresql.engine
  engine_mode       = "provisioned"
  engine_version    = data.aws_rds_engine_version.postgresql.version
  storage_encrypted = true

  vpc_id                 = var.vpc_id
  subnets                = var.private_subnet_ids
  create_security_group  = false
  vpc_security_group_ids = [aws_security_group.rds.id]

  monitoring_interval = 60

  apply_immediately   = true
  skip_final_snapshot = true

  db_parameter_group_name         = aws_db_parameter_group.postgresql13.id
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.postgresql13.id

  serverlessv2_scaling_configuration = {
    min_capacity = 0.5
    max_capacity = 5
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  create_random_password = false
  master_username        = aws_secretsmanager_secret_version.rds_username.secret_string
  master_password        = aws_secretsmanager_secret_version.rds_password.secret_string
}
