data "tls_certificate" "oidc_thumbprint" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [for cert in data.tls_certificate.oidc_thumbprint.certificates : lookup(cert, "sha1_fingerprint", "")]
}
