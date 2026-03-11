terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

#############################
# Variables
#############################

variable "my_ip" {
  description = "IP range allowed for SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}

#############################
# Account Info
#############################

data "aws_caller_identity" "current" {}

#############################
# SNS Topic
#############################

resource "aws_sns_topic" "app" {
  name = "ds5220-dp1"
}

resource "aws_sns_topic_policy" "app_policy" {
  arn = aws_sns_topic.app.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.app.arn
      }
    ]
  })
}

#############################
# S3 Bucket
#############################

resource "aws_s3_bucket" "app" {
  bucket = "ds5220-project1-${data.aws_caller_identity.current.account_id}"

  depends_on = [
    aws_sns_topic.app,
    aws_sns_topic_policy.app_policy
  ]
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket = aws_s3_bucket.app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_notification" "app" {
  bucket = aws_s3_bucket.app.id

  topic {
    topic_arn = aws_sns_topic.app.arn
    events    = ["s3:ObjectCreated:*"]

    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.app_policy]
}

#############################
# IAM Role & Instance Profile
#############################

resource "aws_iam_role" "app" {
  name = "ds5220-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bucket_access" {
  name = "BucketAccessPolicy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.app.arn,
        "${aws_s3_bucket.app.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "ds5220-app-instance-profile"
  role = aws_iam_role.app.name
}

#############################
# Security Group
#############################

resource "aws_security_group" "app" {
  name        = "ds5220-app-sg"
  description = "Allow SSH and API"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "API"
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

#############################
# EC2 Instance
#############################

resource "aws_instance" "app" {
  ami           = "ami-0b6c6ebed2801a5cb"
  instance_type = "t3.micro"
  key_name      = var.key_name

  iam_instance_profile = aws_iam_instance_profile.app.name
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
apt update -y
apt install -y python3 python3-venv python3-pip git

cd /home/ubuntu
git clone https://github.com/sethspire/anomaly-detection-cc-project app
cd app

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "export BUCKET_NAME='${aws_s3_bucket.app.bucket}'" >> /home/ubuntu/.bashrc
echo "BUCKET_NAME='${aws_s3_bucket.app.bucket}'" >> /etc/environment
export BUCKET_NAME='${aws_s3_bucket.app.bucket}'

cat <<EOT > /etc/systemd/system/fastapi.service
[Unit]
Description=FastAPI Service
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/app
Environment="BUCKET_NAME=${aws_s3_bucket.app.bucket}"
ExecStart=/home/ubuntu/app/venv/bin/fastapi run app.py --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOT

mkdir -p /var/log/fastapi
chown -R ubuntu:ubuntu /var/log/fastapi
chmod -R 755 /var/log/fastapi

systemctl daemon-reload
systemctl enable fastapi
systemctl start fastapi
EOF
  )
}

#############################
# Elastic IP
#############################

resource "aws_eip" "app" {
  domain = "vpc"
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}

#############################
# SNS Subscription
#############################

resource "aws_sns_topic_subscription" "app" {
  topic_arn = aws_sns_topic.app.arn
  protocol  = "http"
  endpoint  = "http://${aws_eip.app.public_ip}:8000/notify"

  depends_on = [
    aws_instance.app,
    aws_eip_association.app
  ]
}

#############################
# Outputs
#############################

output "elastic_ip" {
  value = aws_eip.app.public_ip
}

output "bucket_name" {
  value = aws_s3_bucket.app.bucket
}