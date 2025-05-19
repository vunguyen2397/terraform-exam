terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "terraform-vunguyen-bucket"
    key            = "terraform-exam/terraform.tfstate"  
    region         = "us-east-1"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}

provider "aws" {
  region  = "us-east-1" 
}

data "aws_availability_zones" "available" {}

locals {
  is_dev  = terraform.workspace == "dev"
  is_prod = terraform.workspace == "prod"
  is_db   = terraform.workspace == "db"
}

# --- DEV Environment: Create EC2 with Docker & Docker Compose then run all services ---

resource "aws_instance" "dev_ec2" {
  count         = local.is_dev ? 1 : 0     # Check for dev environment
  ami           = "ami-0c94855ba95c71c99"  # Amazon Linux 2
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public[0].id
  security_groups = [aws_security_group.allow_ssh_http.id]
  key_name      = "vuanguyen"   # Change the key_name with other keys if need of declare var.key_name when run terraform apply

  user_data = file("user-data.sh")

  tags = {
    Name = "dev-ec2-docker"
    Env  = terraform.workspace
  }
}

# --- DB Environment: RDS PostgreSQL with Secrets Manager ---

resource "random_password" "db_password" {
  count           = local.is_db ? 1 : 0
  length          = 16
  special         = true
  override_special = "!@#"
}

resource "aws_secretsmanager_secret" "db_secret" {
  count = local.is_db ? 1 : 0
  name  = "db-credentials-${terraform.workspace}"
}

resource "aws_secretsmanager_secret_version" "db_secret_version" {
  count      = local.is_db ? 1 : 0
  secret_id  = aws_secretsmanager_secret.db_secret[0].id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.db_password[0].result
  })
}

resource "aws_db_subnet_group" "db_subnet" {
  count      = local.is_db ? 1 : 0
  name       = "db-subnet-group"
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Env = terraform.workspace
  }
}

resource "aws_db_instance" "postgres" {
  count               = local.is_db ? 1 : 0
  allocated_storage   = 20
  engine              = "postgres"
  engine_version      = "14"
  instance_class      = "db.t3.micro"
  db_name             = "coffeeshop"
  username            = "postgres"
  password            = random_password.db_password[0].result
  parameter_group_name = "default.postgres14"
  skip_final_snapshot = true
  publicly_accessible = false
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]
  db_subnet_group_name  = aws_db_subnet_group.db_subnet[0].name

  tags = {
    Env = terraform.workspace
  }
}
