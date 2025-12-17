# =========================================================
# 1. CONFIGURACIÓN DEL ESTADO (Terraform Cloud)
# =========================================================
terraform {
  cloud {
    organization = "TU_ORGANIZACION" # ⚠️ CAMBIA ESTO
    workspaces {
      name = "TU_WORKSPACE"      # ⚠️ CAMBIA ESTO (ej. mi-proyecto-qa)
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
  default     = "https://github.com/TU_USUARIO/TU_REPO.git" # ⚠️ CAMBIA ESTO POR TU URL HTTPS
}

variable "commit_hash" {
  description = "Cambia este valor para forzar a Terraform a recrear el User Data si actualizas código"
  type        = string
  default     = "latest"
}

# =========================================================
# 3. BÚSQUEDA DE DATOS (Data Sources)
# =========================================================
# Buscamos la AMI de Amazon Linux 2 más reciente
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Buscamos la VPC por defecto de tu cuenta AWS
data "aws_vpc" "default" {
  default = true
}

# Buscamos las Subnets que pertenecen a esa VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# =========================================================
# 4. SEGURIDAD (Security Groups)
# =========================================================

# 4.1 SG del Load Balancer (La puerta de entrada)
resource "aws_security_group" "lb_sg" {
  name        = "lb-sg-${terraform.workspace}"
  description = "Permitir trafico web al Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  # Puerto 80 para el Frontend
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 8000 para la API (Necesario porque tu JS hace fetch al puerto 8000)
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

# 4.2 SG de las Instancias de Aplicación (Backend/Frontend)
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
  # SSH para depuración (Opcional)
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
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"
  key_name      = "Laptop" # ⚠️ VERIFICA QUE TENGAS ESTA KEY EN AWS
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  tags = {
    Name = "DB-Server-${terraform.workspace}"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
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
  subnets            = data.aws_subnets.default.ids
}

# Target Group para el Frontend (Puerto 80)
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

# Target Group para el Backend (Puerto 8000)
resource "aws_lb_target_group" "tg_backend" {
  name     = "tg-back-${terraform.workspace}"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/docs" # FastAPI tiene docs en /docs, sirve para health check
    matcher = "200"
  }
}

# Listener Puerto 80 -> Frontend
resource "aws_lb_listener" "listener_http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_frontend.arn
  }
}

# Listener Puerto 8000 -> Backend
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

# Plantilla de lanzamiento (Launch Template)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "lt-app-${terraform.workspace}"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"
  key_name      = "Laptop" # ⚠️ VERIFICA ESTO
  
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  # User Data codificado en Base64
  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Log para debug en /var/log/user-data.log
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              echo "Iniciando despliegue. Workspace: ${terraform.workspace}"
              
              yum update -y
              amazon-linux-extras install docker -y
              yum install -y git
              service docker start
              usermod -a -G docker ec2-user
              
              # Instalar Docker Compose
              curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose

              # Preparar directorio
              mkdir -p /home/ec2-user/project
              cd /home/ec2-user/project
              
              # Clonar repositorio
              git clone ${var.github_repo} .

              # Lógica de Ramas según el Workspace
              # Si el workspace es "qa", usa la rama qa. Si no, usa main.
              if [ "${terraform.workspace}" == "qa" ]; then
                echo "Cambiando a rama QA"
                git checkout qa
              else
                echo "Usando rama por defecto (main/master)"
                git checkout main
              fi

              # Entrar a carpeta app
              cd app
              
              # Inyectar IP de la Base de Datos al ambiente
              export DB_HOST_ENV="${aws_instance.db_server.private_ip}"
              
              # Levantar Docker Compose
              # Pasamos la variable explícitamente al comando
              DB_HOST_ENV=$DB_HOST_ENV /usr/local/bin/docker-compose up -d --build
              EOF
  )
}

# Grupo de Autoescalado
resource "aws_autoscaling_group" "app_asg" {
  name                = "asg-${terraform.workspace}"
  vpc_zone_identifier = data.aws_subnets.default.ids
  
  # Conectamos a ambos Target Groups (Frontend y Backend)
  target_group_arns   = [
    aws_lb_target_group.tg_frontend.arn, 
    aws_lb_target_group.tg_backend.arn
  ]

  # LOGICA DINAMICA: QA (1 instancia) vs PROD/MAIN (2-3 instancias)
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

# =========================================================
# 8. OUTPUTS
# =========================================================
output "load_balancer_dns" {
  description = "URL para acceder a la aplicacion"
  value       = "http://${aws_lb.app_alb.dns_name}"
}

output "db_private_ip" {
  description = "IP Privada de la DB (Para debug)"
  value       = aws_instance.db_server.private_ip
}