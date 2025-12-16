provider "aws" {
  region = var.aws_region
}

# ==========================================
# 1. SEGURIDAD (Security Groups)
# ==========================================

# SG para el Load Balancer (Acceso público)
resource "aws_security_group" "lb_sg" {
  name = "lb-sg-${terraform.workspace}"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG para las APPS (Solo tráfico desde el Load Balancer)
resource "aws_security_group" "app_sg" {
  name = "app-sg-${terraform.workspace}"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  ingress {
    from_port = 8000 # API
    to_port = 8000
    protocol = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  ingress { # SSH (opcional, para debug)
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG para la DB (Solo tráfico desde las APPS)
resource "aws_security_group" "db_sg" {
  name = "db-sg-${terraform.workspace}"
  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  ingress { # SSH para configurar
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 2. INSTANCIA DE BASE DE DATOS
# ==========================================

resource "aws_instance" "db_server" {
  ami           = "ami-0c02fb55956c7d316" # Amazon Linux 2
  instance_type = "t2.micro"
  security_groups = [aws_security_group.db_sg.name]
  
  tags = {
    Name = "DB-Server-${terraform.workspace}"
  }

  # Script para levantar Postgres automáticamente
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              service docker start
              docker run -d \
                --name postgres-db \
                -e POSTGRES_USER=postgres \
                -e POSTGRES_PASSWORD=postgres \
                -e POSTGRES_DB=taskdb \
                -p 5432:5432 \
                postgres:13
              EOF
}

# ==========================================
# 3. LOAD BALANCER (ALB)
# ==========================================

resource "aws_lb" "app_alb" {
  name               = "app-alb-${terraform.workspace}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = ["subnet-xxxxxx", "subnet-yyyyyy"] # COLOCA AQUÍ TUS SUBNET IDs (o usa data source)
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg-${terraform.workspace}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-xxxxxxx" # COLOCA TU VPC ID AQUÍ

  health_check {
    path = "/"
    matcher = "200"
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ==========================================
# 4. LAUNCH TEMPLATE & ASG (APP)
# ==========================================

data "template_file" "app_user_data" {
  template = <<EOF
#!/bin/bash
yum update -y
yum install -y docker git
service docker start
usermod -a -G docker ec2-user
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir /home/ec2-user/project
cd /home/ec2-user/project
git clone ${var.github_repo} .

BRANCH="main"
if [ "${terraform.workspace}" == "qa" ]; then
  BRANCH="qa"
fi
git checkout $BRANCH

# *** INYECTAR LA IP DE LA DB ***
# Usamos la IP privada de la instancia DB que creamos arriba
export DB_HOST_ENV="${aws_instance.db_server.private_ip}"

cd app
# Pasamos la variable de entorno al docker-compose
DB_HOST_ENV=$DB_HOST_ENV docker-compose up -d --build
EOF
}

resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-lt-${terraform.workspace}"
  image_id      = "ami-0c02fb55956c7d316"
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  user_data = base64encode(data.template_file.app_user_data.rendered)
}

resource "aws_autoscaling_group" "app_asg" {
  name                = "app-asg-${terraform.workspace}"
  desired_capacity    = 2  # Queremos empezar con 2
  max_size            = 3  # Escalar hasta 3
  min_size            = 2  # Mínimo 2
  vpc_zone_identifier = ["subnet-xxxxxx", "subnet-yyyyyy"] # TUS SUBNETS
  target_group_arns   = [aws_lb_target_group.app_tg.arn] # Conectar al Load Balancer

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