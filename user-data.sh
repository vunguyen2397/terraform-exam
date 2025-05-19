
#!/bin/bash
yum update -y
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user
curl -L "https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

# Pull public images from repository cuongopswat + postgres + rabbitmq and tag with local name for each image
docker pull cuongopswat/go-coffeeshop-web && docker tag cuongopswat/go-coffeeshop-web terraform-exam:go-coffeeshop-web
docker pull cuongopswat/go-coffeeshop-proxy && docker tag cuongopswat/go-coffeeshop-proxy terraform-exam:go-coffeeshop-proxy
docker pull cuongopswat/go-coffeeshop-barista && docker tag cuongopswat/go-coffeeshop-barista terraform-exam:go-coffeeshop-barista
docker pull cuongopswat/go-coffeeshop-kitchen && docker tag cuongopswat/go-coffeeshop-kitchen terraform-exam:go-coffeeshop-kitchen
docker pull cuongopswat/go-coffeeshop-counter && docker tag cuongopswat/go-coffeeshop-counter terraform-exam:go-coffeeshop-counter
docker pull cuongopswat/go-coffeeshop-product && docker tag cuongopswat/go-coffeeshop-product terraform-exam:go-coffeeshop-product
docker pull postgres:14-alpine && docker tag postgres:14-alpine terraform-exam:postgres
docker pull rabbitmq:3.11-management-alpine && docker tag rabbitmq:3.11-management-alpine terraform-exam:rabbitmq

# Intended to use DB outside of docker container
# SECRET=$(aws secretsmanager get-secret-value --secret-id db-credentials-db --region us-east-1 --query SecretString --output text)
# DB_USER=$(echo $SECRET | jq -r .username)
# DB_PASS=$(echo $SECRET | jq -r .password)
# RDS_HOST="${rds_endpoint}"

# Create Docker Compose file
cat <<EOL > /home/ec2-user/docker-compose.yml
version: '3.8'
services:
    postgres:
        image: terraform-exam:postgres
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
        image: terraform-exam:rabbitmq
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
        image: terraform-exam:go-coffeeshop-product
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
        image: terraform-exam:go-coffeeshop-counter
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
        image: terraform-exam:go-coffeeshop-proxy
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
        image: terraform-exam:go-coffeeshop-web
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
        image: terraform-exam:go-coffeeshop-barista       
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
        image: terraform-exam:go-coffeeshop-kitchen
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
