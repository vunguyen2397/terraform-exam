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

# --- Basic VPC (shared for all envs) ---
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "iac-vpc"
    Env  = terraform.workspace
  }
}

resource "aws_subnet" "public" {
  count                  = 2
  vpc_id                 = aws_vpc.main.id
  cidr_block             = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone      = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-${count.index}"
    Env  = terraform.workspace
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_association" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Security Group ---
resource "aws_security_group" "allow_ssh_http" {
  name        = "allow_ssh_http"
  description = "Allow SSH and HTTP"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5000
    to_port     = 5002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Env = terraform.workspace
  }
}

# --- DEV Environment: EC2 with Docker & Docker Compose ---

resource "aws_instance" "dev_ec2" {
  count         = local.is_dev ? 1 : 0
  ami           = "ami-0c94855ba95c71c99"  # Amazon Linux 2 (update for your region)
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public[0].id
  security_groups = [aws_security_group.allow_ssh_http.id]
  key_name      = "vuanguyen"  

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user

              curl -L "https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose


              # Start local Docker registry
              docker run -d -p 4000:5000 --restart=always --name registry registry:2

              # Authenticate Docker to local registry (localhost)
              docker login -u testuser -p testpass localhost:4000

              # Pull public images
              docker pull cuongopswat/go-coffeeshop-web
              docker pull cuongopswat/go-coffeeshop-proxy
              docker pull cuongopswat/go-coffeeshop-barista
              docker pull cuongopswat/go-coffeeshop-kitchen
              docker pull cuongopswat/go-coffeeshop-counter
              docker pull cuongopswat/go-coffeeshop-product
              docker pull postgres:14-alpine
              docker pull rabbitmq:3.11-management-alpine

              # Tag and push to private registry (localhost)
              #for image in web proxy barista kitchen counter product; do
              #  docker tag cuongopswat/go-coffeeshop-$image localhost:4000/go-coffeeshop-$image
              #  docker push localhost:4000/go-coffeeshop-$image
              #done
              #docker tag postgres:14-alpine localhost:4000/postgres:14-alpine
              #docker push localhost:4000/postgres:14-alpine
              #docker tag rabbitmq:3.11-management-alpine localhost:4000/rabbitmq:3.11-management-alpine
              #docker push localhost:4000/rabbitmq:3.11-management-alpine

              # Create Docker Compose file
              cat <<EOL > /home/ec2-user/docker-compose.yml
              version: '3.8'
              services:
                postgres:
                  image: postgres:14-alpine
                  ports:
                    - "5432:5432"
                  environment:
                    - POSTGRES_DB=coffeeshop
                    - POSTGRES_USER=postgres
                    - POSTGRES_PASSWORD=admin
                  healthcheck:
                    test: ["CMD-SHELL", "pg_isready -U postgres"]
                    interval: 10s
                    timeout: 5s
                    retries: 5

                rabbitmq:
                  image: rabbitmq:3.11-management-alpine
                  ports:
                    - "5672:5672"
                    - "15672:15672"
                  environment:
                    - RABBITMQ_DEFAULT_USER=admin
                    - RABBITMQ_DEFAULT_PASS=admin
                  healthcheck:
                    test: ["CMD-SHELL", "rabbitmq-diagnostics -q check_running"]
                    interval: 10s
                    timeout: 5s
                    retries: 5

                product:
                  image: cuongopswat/go-coffeeshop-product
                  ports:
                    - "5001:5001"
                  environment:
                    - APP_NAME=product
                    - POSTGRES_DB=coffeeshop
                    - POSTGRES_USER=postgres
                    - POSTGRES_PASSWORD=admin
                  depends_on:
                    postgres:
                      condition: service_healthy

                counter:
                  image: cuongopswat/go-coffeeshop-counter
                  ports:
                    - "5002:5002"
                  environment:
                    - APP_NAME=counter
                    - IN_DOCKER=true
                    - PG_URL=postgresql://postgres:admin@postgres:5432/coffeeshop
                    - PG_DSN_URL=host=postgres user=postgres password=admin dbname=coffeeshop sslmode=disable
                    - RABBITMQ_URL=amqp://admin:admin@rabbitmq:5672/
                    - PRODUCT_CLIENT_URL=product:5001
                  depends_on:
                    postgres:
                      condition: service_healthy
                    rabbitmq:
                      condition: service_healthy

                proxy:
                  image: cuongopswat/go-coffeeshop-proxy
                  ports:
                    - "5000:5000"
                  environment:
                    - APP_NAME=proxy
                    - GRPC_PRODUCT_HOST=product
                    - GRPC_PRODUCT_PORT=5001
                    - GRPC_COUNTER_HOST=counter
                    - GRPC_COUNTER_PORT=5002
                  depends_on:
                    - product
                    - counter
                  healthcheck:
                    test: ["CMD", "curl", "-f", "http://localhost:5000"]
                    interval: 30s
                    timeout: 10s
                    retries: 3

                web:
                  image: cuongopswat/go-coffeeshop-web
                  ports:
                    - "8888:8888"
                  environment:
                    - REVERSE_PROXY_URL=http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):5000
                    - WEB_PORT=8888
                  depends_on:
                    - proxy
                  healthcheck:
                    test: ["CMD", "curl", "-f", "http://localhost:8888"]
                    interval: 30s
                    timeout: 10s
                    retries: 3

                barista:
                  image: cuongopswat/go-coffeeshop-barista
                  environment:
                    - APP_NAME=barista
                    - IN_DOCKER=true
                    - PG_URL=postgresql://postgres:admin@postgres:5432/coffeeshop
                    - PG_DSN_URL=host=postgres user=postgres password=admin dbname=coffeeshop sslmode=disable
                    - RABBITMQ_URL=amqp://admin:admin@rabbitmq:5672/
                  depends_on:
                    postgres:
                      condition: service_healthy
                    rabbitmq:
                      condition: service_healthy

                kitchen:
                  image: cuongopswat/go-coffeeshop-kitchen
                  environment:
                    - APP_NAME=kitchen
                    - IN_DOCKER=true
                    - PG_URL=postgresql://postgres:admin@postgres:5432/coffeeshop
                    - PG_DSN_URL=host=postgres user=postgres password=admin dbname=coffeeshop sslmode=disable
                    - RABBITMQ_URL=amqp://admin:admin@rabbitmq:5672/
                  depends_on:
                    postgres:
                      condition: service_healthy
                    rabbitmq:
                      condition: service_healthy
              EOL

              # Run Docker Compose
              cd /home/ec2-user && docker-compose up -d
              EOF

  tags = {
    Name = "dev-ec2-docker"
    Env  = terraform.workspace
  }
}

# --- PROD Environment: EKS Cluster ---

resource "aws_eks_cluster" "prod_eks" {
  count = local.is_prod ? 1 : 0

  name     = "prod-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role[0].arn

  vpc_config {
    subnet_ids = aws_subnet.public[*].id
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy]
}

resource "aws_iam_role" "eks_cluster_role" {
  count = local.is_prod ? 1 : 0
  name  = "eks_cluster_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  count      = local.is_prod ? 1 : 0
  role       = aws_iam_role.eks_cluster_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node_group_role" {
  count = local.is_prod ? 1 : 0
  name  = "eks_node_group_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  count      = local.is_prod ? 1 : 0
  role       = aws_iam_role.eks_node_group_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count      = local.is_prod ? 1 : 0
  role       = aws_iam_role.eks_node_group_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSCNIPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  count      = local.is_prod ? 1 : 0
  role       = aws_iam_role.eks_node_group_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "prod_node_group" {
  count = local.is_prod ? 1 : 0

  cluster_name    = aws_eks_cluster.prod_eks[0].name
  node_group_name = "prod-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role[0].arn
  subnet_ids      = aws_subnet.public[*].id

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["t3.medium"]
  disk_size      = 20
  ami_type       = "AL2_x86_64"

  tags = {
    Environment = terraform.workspace
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
  engine_version      = "14-apline"
  instance_class      = "db.t3.micro"
  db_name             = "my_local_db"
  username            = "postgres"
  password            = random_password.db_password[0].result
  parameter_group_name = "default.postgres15"
  skip_final_snapshot = true
  publicly_accessible = false
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]
  db_subnet_group_name  = aws_db_subnet_group.db_subnet[0].name

  tags = {
    Env = terraform.workspace
  }
}
