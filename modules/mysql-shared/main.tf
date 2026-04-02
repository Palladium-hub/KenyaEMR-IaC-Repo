resource "kubernetes_namespace" "mysql" {
  metadata {
    name = "mysql"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata]
  }
}

resource "kubernetes_config_map" "mysql_config" {
  metadata {
    name      = "mysql-config"
    namespace = "mysql"
  }

  data = {
    "my.cnf" = <<EOT
[mysqld]
sql_mode="ALLOW_INVALID_DATES,NO_ENGINE_SUBSTITUTION"
log_bin_trust_function_creators = 1
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_buffer_pool_size = 128M
key_buffer_size = 32M
log_error = /var/log/mysql/error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow-query.log
long_query_time = 200
log_queries_not_using_indexes = 1
general_log = 0
general_log_file = /var/log/mysql/general.log
max_connections = 1000
thread_cache_size = 100
interactive_timeout = 300
wait_timeout = 300


!includedir /etc/mysql/conf.d/
    EOT
  }
}

resource "kubernetes_config_map" "init_sql" {
  metadata {
    name      = "mysql-init-sql"
    namespace = "mysql"
  }

  data = {
    "tenants.sql" = file("${path.module}/init/tenants.sql")
  }
}

resource "kubernetes_stateful_set" "mysql" {
  metadata {
    name      = "mysql"
    namespace = "mysql"
    labels = {
      app = "mysql"
    }
  }

  spec {
    service_name = "mysql"
    replicas     = 1

    selector {
      match_labels = {
        app = "mysql"
      }
    }

    template {
      metadata {
        labels = {
          app = "mysql"
        }
      }

      spec {
        container {
          name  = "mysql"
          image = "mysql:8.0"

          port {
            container_port = 3306
          }

          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = "training"
          }

          args = [
            "--default-authentication-plugin=mysql_native_password"
          ]

          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }

          volume_mount {
            name       = "init-sql"
            mount_path = "/docker-entrypoint-initdb.d"
          }

          # Mount custom my.cnf
          volume_mount {
            name       = "mysql-config"
            mount_path = "/etc/my.cnf"
            sub_path   = "my.cnf"
          }
        }

        # volumes for config maps
        volume {
          name = "init-sql"
          config_map {
            name = kubernetes_config_map.init_sql.metadata[0].name
          }
        }

        volume {
          name = "mysql-config"
          config_map {
            name = kubernetes_config_map.mysql_config.metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "mysql-storage"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "10Gi"
          }
        }
        # Optional: specify your cluster's storage class
        # storage_class_name = "standard"
      }
    }
  }
}

resource "kubernetes_service" "mysql" {
  metadata {
    name      = "mysql"
    namespace = "mysql"
  }

  spec {
    cluster_ip = "None" 
    selector = {
      app = "mysql"
    }

    port {
      port        = 3306
      target_port = 3306
    }
  }
}
