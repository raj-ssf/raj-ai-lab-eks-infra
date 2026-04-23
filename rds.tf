# Plain RDS Postgres single-instance. Chose this over Aurora Serverless v2
# because SCP p-hd2gn6n3 explicitly denies rds:CreateDBInstance for the
# db.serverless class (Aurora's serverless v2 instance type). Myriad's
# existing myriad-backstage-poc RDS uses db.t4g.micro + engine=postgres,
# which the SCP allows — we follow the same shape.
#
# Cost: db.t4g.micro at $0.016/hr × 730 ≈ $12/mo + ~$2/mo storage. ~4x
# cheaper than Aurora Serverless v2 minimum floor.

resource "random_password" "rds_master" {
  length  = 24
  # Avoid special chars that need URL-encoding in the connection_url that
  # Vault uses to auth against Postgres.
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "Postgres 5432 from EKS node SG (pods via VPC CNI)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-rds"
  })
}

resource "aws_db_subnet_group" "rag" {
  name       = "${var.cluster_name}-rag"
  subnet_ids = data.aws_subnets.private.ids

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-rag"
  })
}

resource "aws_db_instance" "rag" {
  identifier     = "${var.cluster_name}-rag"
  engine         = "postgres"
  engine_version = "16.13"
  instance_class = "db.t4g.micro"

  db_name  = "ragdb"
  username = "rootadmin"
  password = random_password.rds_master.result
  port     = 5432

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.rag.name
  publicly_accessible    = false
  multi_az               = false

  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1

  apply_immediately = true

  tags = local.common_tags
}

output "rds_endpoint" {
  # aws_db_instance.endpoint includes the :5432 port suffix — strip for clean
  # connection URLs.
  value       = aws_db_instance.rag.address
  description = "Postgres endpoint — use from in-cluster pods (rag-service, etc.)"
}

output "rds_master_password" {
  value       = random_password.rds_master.result
  sensitive   = true
  description = "Admin password Vault uses to connect. Retrieve: terraform output -raw rds_master_password"
}
