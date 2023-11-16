
# Define an  AWS launch configuration 
resource "aws_launch_configuration" "example" {
  image_id        = var.ami
  instance_type   = var.instance_type
  security_groups = [aws_security_group.instance.id]

  #EOF allows create multiline strings
  #User data runs on the first initial boot 
  # Bash script writes text into index.html and runs busybox to start web server on port 8080 to serve that file

  #user_data = <<-EOF
                #!/bin/bash
                #echo "Hello, World" > index.html
               # nohup busybox httpd -f -p ${var.server_port} &
                #EOF

  # Render user data script as a template
  # Creates HTML file and starts web server using BusyBox
  user_data     = templatefile("${path.module}/user-data.sh", {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
    server_text = var.server_text
  })

  # Required when using a launch configuration with an auto scaling group 
  # it configures how that resource is created, updated, and/or deleted
  lifecycle {
    create_before_destroy = true
  }
}

# run between 2 and 10 instances each tagged with tag name
resource "aws_autoscaling_group" "example" {
  # concatenate to depend on launch config's name so each time its replaced, this 
  # ASG is also replaced 
  name = "${var.cluster_name}-${aws_launch_configuration.example.name}"

  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnets.default.ids


  target_group_arns = [aws_lb_target_group.asg.arn]
  #default healthchecktype is set to EC2
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size
 
  # Wait for at least this many instances to pass health checks before
  # considering the ASG deployment complete
  min_elb_capacity = var.min_size

  # When replacing this ASG, create the replacment first and only delete 
  # the original after
  lifecycle {
    
    create_before_destroy = true
  }

  # Tags for instances created by the ASG
  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  # Create dynamic tags based on custom_tags input variable
  # Create multiple tags dynamically based on map/list of values
  dynamic "tag" {
    for_each = {
      for key, value in var.custom_tags:
      key => upper(value)
      if key != "Name"
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Create schedules to scale the ASG in and out
resource "aws_autoscaling_schedule" "scale_out_during_business_hours" {
  count = var.enable_autoscaling ? 1 : 0

  scheduled_action_name  = "${var.cluster_name}-scale-out-during-business-hours"
  min_size               = 2
  max_size               = 2
  desired_capacity       = 2
  recurrence             = "0 9 * * *"
  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_autoscaling_schedule" "scale_in_at_night" {
  count = var.enable_autoscaling ? 1 : 0

  scheduled_action_name  = "${var.cluster_name}-scale-in-at-night"
  min_size               = 2
  max_size               = 2
  desired_capacity       = 2
  recurrence             = "0 17 * * *"
  autoscaling_group_name = aws_autoscaling_group.example.name
}


# Define as AWS Security Group for instances 
resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"
}

# Define a rule to allow inbound HTTP traffic to Security Group
resource "aws_security_group_rule" "allow_server_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port   = var.server_port
  to_port     = var.server_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}


# Define data sources to retrieve information about VPC and subnets
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Create an AWS application load balancer
resource "aws_lb" "example" {
  name               = var.cluster_name
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

# Define listener for ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = local.http_port
  protocol          = "HTTP"

  # By default, return simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}


# Create target group for ASG
resource "aws_lb_target_group" "asg" {
  name     = var.cluster_name
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  # Check instances periodically sending HTTP request to each instance to match configured matcher 
  # Configure health checks for instances in target group
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Create listener rules
# add listener rule that sends requests that match any path to target group containing ASG
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

# Define security group for ALB
resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
}

# Define rules to allow inbound HTTP traffic and all outbound traffic for security group
resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port         = local.http_port
  to_port           = local.http_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port         = local.any_port
  to_port           = local.any_port
  protocol          = local.any_protocol
  cidr_blocks       = local.all_ips
}

# Define data source to retrieve information from remote terraform state file
data "terraform_remote_state" "db" {
    backend = "s3"

    config = {
        bucket = var.db_remote_state_bucket
        key    = var.db_remote_state_key
        region = "us-east-2"
    }
}

# Local values in locals block instead of input variables for commonly used constants
 locals {
  http_port = 80
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips = ["0.0.0.0/0"]
}