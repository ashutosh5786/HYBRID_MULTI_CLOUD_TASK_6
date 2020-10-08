provider "aws" {
  region = "ap-south-1"
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating The Security Grp For RDS

//Creating The Security Group And Allowing The HTTP and SSH
resource "aws_security_group" "rds-sec-grp" {

  name        = "RDS-Securty-Grp"
  description = "Allow MySQL Ports"
 
  ingress {
    description = "Allowing Connection for SSH"
    from_port   = 3306
    to_port     = 3306
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
    Name = "RDS-Server"
  }
}


//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating the RDS instances template

resource "aws_db_instance" "rds" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  name                 = "mydb"
  username             = "wp"
  password             = "wordpress123"
  parameter_group_name = "default.mysql5.7"
  publicly_accessible = true
  skip_final_snapshot = true
  vpc_security_group_ids = [aws_security_group.rds-sec-grp.id]
  tags = {
  name = "RDS_Main"
   }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// IAM Role for EKS Cluster

resource "aws_iam_role" "role" {
  name = "eks-cluster"

    assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "Mine-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.role.name
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating Cluster

resource "aws_eks_cluster" "MyCluster" {

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSVPCResourceController,
    aws_iam_role_policy_attachment.Mine-AmazonEKSClusterPolicy
  ]
  name = "Cluster"
  role_arn = aws_iam_role.role.arn


  vpc_config {
    subnet_ids = ["subnet-d2e2d8ba", "subnet-83056ecf"]
  }

  tags = {
    Name = "EKS_Subnet"
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating EKS Node Grp's IAM role

resource "aws_iam_role" "role2" {
  name = "eks-node-group"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.role2.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.role2.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.role2.name
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating Node Group

resource "aws_eks_node_group" "node" {
  cluster_name    = aws_eks_cluster.MyCluster.name
  node_group_name = "node"
  node_role_arn   = aws_iam_role.role2.arn
  subnet_ids      = ["subnet-d2e2d8ba", "subnet-83056ecf"]
  instance_types = ["t2.micro"]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
  ]
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.MyCluster.endpoint
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Configuring the Kube config file

resource "null_resource" "null1" {
 depends_on = [
	aws_eks_node_group.node
 ]

provisioner "local-exec" {
	command = "aws eks --region ap-south-1 update-kubeconfig --name Cluster"
}
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//Creating The Deployment
provider "kubernetes" {
}

resource "kubernetes_deployment" "mydeployment" {
   depends_on = [
	null_resource.null1
]
  metadata {
    name = "wordpress"
    labels = {
      app = "wordpress"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "wordpress"
      }
    }

    template {
      metadata {
        labels = {
          app = "wordpress"
        }
      }

      spec {
        container {
          image = "wordpress"
          name  = "wordpress:4.8-apache"
          env{
            name = "WORDPRESS_DB_HOST"
            value = aws_db_instance.rds.address
          }
          env{
            name = "WORDPRESS_DB_USER"
            value = aws_db_instance.rds.name
          }
          env{
            name = "WORDPRESS_DB_PASSWORD"
             value = aws_db_instance.rds.password
          }
          port {
            container_port = 80
          }

          }
        }
      }
    }
  }


resource "kubernetes_service" "Myservice"{
  depends_on = [kubernetes_deployment.mydeployment]
  metadata {
    name = "exposeportofwp"
  }
  spec {
    selector = {
      app = kubernetes_deployment.mydeployment.metadata.0.labels.app
    }
    port {
      node_port = 30001
      port        = 80
      target_port = 80
    }
    type = "LoadBalancer"
  }
}
