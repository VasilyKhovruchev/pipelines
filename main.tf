terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"


backend "s3" {
  endpoints   = { s3 = "https://storage.yandexcloud.net" }
  bucket     = "terraform-storage"
  key        = "infrastructure/terraform.tfstate"
  region     = "ru-central1"
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_s3_checksum            = true

  }
}

##################


resource "yandex_vpc_network" "vpc-project" {
  name = "nixys"
}

resource "yandex_vpc_subnet" "test-subnet" {
  v4_cidr_blocks = ["10.2.0.0/16"]
  network_id     = yandex_vpc_network.vpc-project.id
  zone           = "ru-central1-d"
  route_table_id = yandex_vpc_route_table.rt.id
}


locals {
  k8s_version = "1.28"
  sa_name     = "myaccount"
  folder_id = "b1gr7bua55v80l9i85tr"
  cloud_id = "b1gtt6jg051fooahq4vq"
  version = "1.28"
}


resource "yandex_iam_service_account" "myaccount" {
  name        = local.sa_name
  description = "K8S service account"
}


resource "yandex_vpc_gateway" "nat_gateway" {
  name = "test-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  name       = "route-table"
  network_id = yandex_vpc_network.vpc-project.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

###   роли сервисного аккаунта 

resource "yandex_resourcemanager_folder_iam_member" "loadbalancer-admin" {
  folder_id = local.folder_id
  role      = "load-balancer.admin"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id = local.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-admin" {
  folder_id = local.folder_id
  role      = "k8s.admin"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-clusters-agent" {
  folder_id = local.folder_id
  role      = "k8s.clusters.agent"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "vpc-public-admin" {
  folder_id = local.folder_id
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "images-puller" {
  folder_id = local.folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_kms_symmetric_key" "kms-key" {
  name              = "kms-key"
  default_algorithm = "AES_128"
  rotation_period   = "8760h" # 1 год.
}

resource "yandex_resourcemanager_folder_iam_member" "viewer" {
  folder_id = local.folder_id
  role      = "viewer"
  member    = "serviceAccount:${yandex_iam_service_account.myaccount.id}"
}

resource "yandex_kubernetes_cluster" "k8s-test" {
  network_id = yandex_vpc_network.vpc-project.id
  master {
    version = local.k8s_version
    zonal {
      zone      = yandex_vpc_subnet.test-subnet.zone
      subnet_id = yandex_vpc_subnet.test-subnet.id
    }
    public_ip = true
    security_group_ids = [yandex_vpc_security_group.k8s-public-services.id]
  }
  service_account_id      = yandex_iam_service_account.myaccount.id
  node_service_account_id = yandex_iam_service_account.myaccount.id
  depends_on = [
    yandex_resourcemanager_folder_iam_member.k8s-clusters-agent,
    yandex_resourcemanager_folder_iam_member.vpc-public-admin,
    yandex_resourcemanager_folder_iam_member.images-puller
  ]
  kms_provider {
    key_id = yandex_kms_symmetric_key.kms-key.id
  }
}

# yandex_kubernetes_node_group

resource "yandex_kubernetes_node_group" "k8s_node_group" {
  cluster_id  = yandex_kubernetes_cluster.k8s-test.id
  name        = "k8s-node-group"
  description = "Группа виртуальных машин для обслуживания кластера"
  version     = "1.28"

  labels = {
    "commonworkers" = "true"
    "application" = "frontend"
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat        = false
      subnet_ids = [yandex_vpc_subnet.test-subnet.id]
    }

    resources {
      cores         = 2
      memory        = 4
      core_fraction = 50
    }

    boot_disk {
      type = "network-hdd"
      size = 32
    }

    scheduling_policy {
      preemptible = true
    }

    metadata = {
      ssh-keys = "ubuntu:${file("pub")}"
    }

  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    location {
      zone = "ru-central1-d"
    }
  }

  maintenance_policy {
    auto_upgrade = true
    auto_repair  = true

    maintenance_window {
      day        = "monday"
      start_time = "15:00"
      duration   = "3h"
    }

    maintenance_window {
      day        = "friday"
      start_time = "10:00"
      duration   = "4h30m"
    }
  }
}


locals {
  kubeconfig = <<KUBECONFIG
apiVersion: v1
clusters:
- cluster:
    server: ${yandex_kubernetes_cluster.k8s-test.master[0].external_v4_endpoint}
    certificate-authority-data: ${base64encode(yandex_kubernetes_cluster.k8s-test.master[0].cluster_ca_certificate)}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: yc
  name: ycmk8s
current-context: ycmk8s
users:
- name: yc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: yc
      args:
      - k8s
      - create-token
KUBECONFIG
}

################################

output "kubeconfig" {
  value = local.kubeconfig
}

#####################################

resource "yandex_vpc_security_group" "k8s-public-services" {
  name        = "k8s-public-services"
  network_id  = yandex_vpc_network.vpc-project.id

  ingress {
    protocol          = "TCP"
    description       = "manage k8s cluster"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 443
  }

  ingress {
    protocol          = "TCP"
    description       = "manage k8s cluster 2"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 6443
  }

##############################################

  ingress {
    protocol          = "ANY"
    description       = "all inbound traffic"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 65535
  }

  ingress {
    protocol          = "ICMP"
    description       = "all icmp traffic"
    v4_cidr_blocks    = ["0.0.0.0/0"]
  }

##############################################

  ingress {
    protocol          = "TCP"
    predefined_target = "loadbalancer_healthchecks"
    from_port         = 0
    to_port           = 65535
  }
  ingress {
    protocol          = "ANY"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }
  ingress {
    protocol          = "ANY"
    v4_cidr_blocks    = concat(yandex_vpc_subnet.test-subnet.v4_cidr_blocks)
    from_port         = 0
    to_port           = 65535
  }
  ingress {
    protocol          = "ICMP"
    v4_cidr_blocks    = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  ingress {
    protocol          = "TCP"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 30000
    to_port           = 32767
  }
  egress {
    protocol          = "ANY"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 65535
  }
}

###################################################
# additional packages


provider "helm" {
  kubernetes {
    host                   = yandex_kubernetes_cluster.k8s-test.master[0].external_v4_endpoint
    cluster_ca_certificate = yandex_kubernetes_cluster.k8s-test.master[0].cluster_ca_certificate
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["k8s", "create-token"]
      command     = "yc"
    }
  }
}

provider "kubernetes" {
  host                   = yandex_kubernetes_cluster.k8s-test.master[0].external_v4_endpoint
  cluster_ca_certificate     = yandex_kubernetes_cluster.k8s-test.master[0].cluster_ca_certificate
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["k8s", "create-token"]
    command     = "yc"
  }
}

#resource "kubernetes_namespace" "ingress" {
#  metadata {
#    name = "ingress-nginx"
#  }
#}

resource "kubernetes_namespace" "cert-manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}


#resource "helm_release" "ingress_nginx" {
#  name       = "ingress-nginx"
#  repository = "https://kubernetes.github.io/ingress-nginx"
#  chart      = "ingress-nginx"
#  version    = "4.8.2"
#  namespace  = "ingress-nginx"
#  wait       = true
#  depends_on = [
#    yandex_kubernetes_node_group.k8s_node_group
#  ]
#}

resource "helm_release" "cert-manager" {
  namespace        = "cert-manager"
  name             = "jetstack"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.9.1"
  wait             = true
  depends_on = [
    yandex_kubernetes_node_group.k8s_node_group
  ]
  set {
    name  = "installCRDs"
    value = true
  }
}

resource "helm_release" "prometheus" {
  namespace        = "monitoring"
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "55.5.0"
  wait             = true
  depends_on = [
    yandex_kubernetes_node_group.k8s_node_group
  ]
}
