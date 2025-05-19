# terraform-exam
# Summary: this architect will create separate workspaces for Dev and DB, with Dev workspace will create an EC2 instance running docker images for coffeshop application, while DB workspace will create a PostgreSQL using RDS and have automatic password management via Secrets Manager


# Architect:
**In Dev workspace:**
-   Create a t3.micro EC2 instance, public subnet placement, SSH/HTTP security group access
-   Then runs user-data.sh to:
-   Install Docker and Docker Compose
-   Pull and tag container images
-   Configure and start containers via docker-compose
-   Run all services from the images by order: Postgres -> Rabbitmq -> Product -> Counter -> the rest
-   To check if the web is online, access through http://<instance_ipv4>:8888

**In DB workspace:**
-   Secret Management generates a random 16-character password with special characters and stores credentials in AWS Secrets Manager as db-credentials-db
-   RDS PostgresQL Database with t3.micro instance, using PostgreSQL 14, uses a public subnet group, database name: "coffeeshop", automatic password management via Secrets Manager

# Component:
**main.tf**: use to create Dev and DB workspace, with backend from remote S3

**network.tf**: Configure network and security group, shared to all workspaces
 
**user-data.sh**: shellscript to run inside EC2 instead, will install docker, docker-compose, pull image and tag then run all services
**output.tf**: for testing purpose, will printout EC2 instance's IPv4 after ran Dev workspace

# Userguide:
First run command:
-       terraform init

To use Dev workspace, run command:
-       terraform workspace select dev || terraform workspace new dev
-       terraform plan
-       terraform apply -auto-approve

To use DB workspace, run command:
-       terraform workspace select db || terraform workspace new db
-       terraform plan
-       terraform apply -auto-approve

To delete Dev workspace run, use command:
-       terraform workspace select dev 
-       terraform destroy -auto-approve

To use DB workspace run, use command:
-       terraform workspace select db
-       terraform destroy -auto-approve

To check for the homepage of the application, use http://<EC2_instance_IPv4>:8888
To verify Secrets Manager Entry, run: (required AWS Cli installed)
-       aws secretsmanager get-secret-value --secret-id db-credentials-${terraform.workspace} --region us-east-1