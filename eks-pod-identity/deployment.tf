resource "kubernetes_deployment" "demo" {
  metadata {
    name      = "cw-writer"
    namespace = var.namespace
    labels = {
      app = "cw-writer"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "cw-writer"
      }
    }

    template {
      metadata {
        labels = {
          app = "cw-writer"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.demo.metadata[0].name

        container {
          name  = "aws-cli"
          image = "amazon/aws-cli:2.17.50"
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            aws logs create-log-group --log-group-name /demo/pod-identity --region ${var.region} || true && \
            aws logs create-log-stream --log-group-name /demo/pod-identity --log-stream-name $HOSTNAME --region ${var.region} || true && \
            aws logs put-log-events --log-group-name /demo/pod-identity --log-stream-name $HOSTNAME --log-events '[{"timestamp":'$(($(date +%s%3N)))',"message":"hello from pod identity"}]' --region ${var.region} && \
            sleep 3600
            EOT
          ]
        }
      }
    }
  }
}
