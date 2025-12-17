# =========================================================
# 1. CONFIGURACIÓN DEL ESTADO (Terraform Cloud)
# =========================================================
terraform {
  cloud {
    organization = "org-distribuida-carlos-practica" 
    workspaces {
      name = "qa-and-main" 
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =========================================================
# 2. VARIABLES
# =========================================================
variable "github_repo" {
  description = "URL del repositorio para clonar la app"
  type        = string
  default     = "https://github.com/carlosrm12/practica_dis.git" 
}

variable "commit_hash" {
  description = "Hash del commit para forzar recreación del Launch Template"
  type        = string
  default     = "latest"
}

# =========================================================
# 3. BÚSQUEDA DE DATOS (Data Sources)
# =========================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "mis_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

# =========================================================
# 4. SEGURIDAD (Security Groups)
# =========================================================

# 4.1 SG del Load Balancer
resource "aws_security_group" "lb_sg" {
  name        = "lb-sg-${terraform.workspace}"
  description = "Permitir trafico web al Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4.2 SG de las Apps
resource "aws_security_group" "app_sg" {
  name        = "app-sg-${terraform.workspace}"
  description = "Solo trafico desde el Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4.3 SG de la Base de Datos
resource "aws_security_group" "db_sg" {
  name        = "db-sg-${terraform.workspace}"
  description = "Solo trafico desde la App"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  
  # SSH opcional para debuggear DB si fuera necesario
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================================================
# 5. BASE DE DATOS (Instancia EC2 con Docker)
# =========================================================
resource "aws_instance" "db_server" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"             
  key_name      = "Laptop"
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  # Forzamos que la DB esté en una subnet específica si quieres, o dejamos que AWS elija
  # Para simplicidad dejamos que AWS elija una de las default
  
  tags = {
    Name = "DB-Server-${terraform.workspace}"
  }

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y docker
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user
              docker run -d \
                --name postgres-db \
                --restart always \
                -e POSTGRES_USER=postgres \
                -e POSTGRES_PASSWORD=postgres \
                -e POSTGRES_DB=taskdb \
                -p 5432:5432 \
                postgres:13
              EOF
}

# =========================================================
# 6. LOAD BALANCER (ALB)
# =========================================================
resource "aws_lb" "app_alb" {
  name               = "alb-${terraform.workspace}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = data.aws_subnets.mis_subnets.ids 
}

resource "aws_lb_target_group" "tg_frontend" {
  name     = "tg-front-${terraform.workspace}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/"
    matcher = "200"
  }
}

resource "aws_lb_target_group" "tg_backend" {
  name     = "tg-back-${terraform.workspace}"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/docs" 
    matcher = "200"
  }
}

resource "aws_lb_listener" "listener_http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_frontend.arn
  }
}

resource "aws_lb_listener" "listener_api" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "8000"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_backend.arn
  }
}

# =========================================================
# 7. AUTOSCALING GROUP (APP)
# =========================================================

resource "aws_launch_template" "app_lt" {
  name_prefix   = "lt-app-${terraform.workspace}"
  image_id      = data.aws_ami.al2023.id 
  instance_type = "t3.micro"             
  key_name      = "Laptop"
  
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = base64encode(<<-EOF
              #!/bin/bash
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Iniciando despliegue. Workspace: ${terraform.workspace}"
              echo "Commit Hash: ${var.commit_hash}"
              
              dnf update -y
              dnf install -y docker git
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user
              
              # Instalar Docker Compose
              curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose

              mkdir -p /home/ec2-user/project
              cd /home/ec2-user/project
              
              git clone ${var.github_repo} .

              if [ "${terraform.workspace}" == "qa" ]; then
                git checkout qa
              else
                git checkout main
              fi

              cd app
              export DB_HOST_ENV="${aws_instance.db_server.private_ip}"
              
              # Levantar servicios
              DB_HOST_ENV=$DB_HOST_ENV /usr/local/bin/docker-compose up -d --build
              EOF
  )
}

resource "aws_autoscaling_group" "app_asg" {
  # Nombre dinámico vital para el deploy.yml
  name                = "asg-${terraform.workspace}"
  vpc_zone_identifier = data.aws_subnets.mis_subnets.ids 
  
  target_group_arns   = [
    aws_lb_target_group.tg_frontend.arn, 
    aws_lb_target_group.tg_backend.arn
  ]

  # Lógica Dinámica de capacidad
  desired_capacity = terraform.workspace == "main" ? 2 : 1
  max_size         = terraform.workspace == "main" ? 3 : 1
  min_size         = terraform.workspace == "main" ? 2 : 1

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "App-Instance-${terraform.workspace}"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "politica-cpu-10"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name # Referencia dinámica
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 10.0
  }
}

# =========================================================
# 8. OUTPUTS
# =========================================================
output "load_balancer_dns" {
  value = "http://${aws_lb.app_alb.dns_name}"
}

output "db_private_ip" {
  value = aws_instance.db_server.private_ip
}