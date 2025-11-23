# ==============================================================================
# Gatekeeper + Ratify with AWS Signer Integration
# ==============================================================================
# This configuration deploys Gatekeeper and Ratify to verify container image
# signatures using AWS Signer. Key AWS Signer-specific requirements:
#
# 1. IAM Policy: Must include leading "/" in signing-jobs ARN:
#    arn:aws:signer:REGION:ACCOUNT:/signing-jobs/* (note the colon-slash)
#
# 2. Trust Store Type: AWS Signer requires "signingAuthority" type, not "ca":
#    verificationCertStores:
#      signingAuthority:
#        certs: [...]
#    trustStores:
#      - signingAuthority:certs
#
# 3. Certificate: AWS Signer root certificate required for signature validation
# ==============================================================================

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

# Get OIDC provider - construct ARN from cluster OIDC issuer
locals {
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"
  oidc_provider_url = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# IAM policy for Ratify to check AWS Signer revocation status
# IMPORTANT: ARN must include leading "/" before "signing-jobs"
data "aws_iam_policy_document" "ratify_signer_permissions" {
  statement {
    sid     = "SignerRevocation"
    actions = ["signer:GetRevocationStatus"]
    effect  = "Allow"
    resources = [
      aws_signer_signing_profile.eks_secure.arn,
      "arn:aws:signer:${var.region}:${data.aws_caller_identity.current.account_id}:/signing-jobs/*"
    ]
  }
}

resource "aws_iam_role" "ratify" {
  name = "${var.cluster_name}-ratify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:gatekeeper-system:ratify-admin"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ratify_ecr" {
  role       = aws_iam_role.ratify.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "ratify_signer" {
  role   = aws_iam_role.ratify.id
  policy = data.aws_iam_policy_document.ratify_signer_permissions.json
}

resource "kubernetes_namespace" "gatekeeper_system" {
  metadata {
    name = "gatekeeper-system"
  }
}

resource "kubernetes_service_account" "ratify" {
  metadata {
    name      = "ratify-admin"
    namespace = kubernetes_namespace.gatekeeper_system.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ratify.arn
    }
  }

  depends_on = [kubernetes_namespace.gatekeeper_system]
}


provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "gatekeeper" {
  name       = "gatekeeper"
  namespace  = kubernetes_namespace.gatekeeper_system.metadata[0].name
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"

  depends_on = [kubernetes_namespace.gatekeeper_system]

  set {
    name  = "enableExternalData"
    value = "true"
  }

  set {
    name  = "validatingWebhookTimeoutSeconds"
    value = "5"
  }

  set {
    name  = "mutatingWebhookTimeoutSeconds"
    value = "10"
  }

  set {
    name  = "externaldataProviderResponseCacheTTL"
    value = "0s"
  }
}

resource "helm_release" "ratify" {
  name       = "ratify"
  namespace  = kubernetes_namespace.gatekeeper_system.metadata[0].name
  repository = "https://notaryproject.github.io/ratify"
  chart      = "ratify"

  depends_on = [
    kubernetes_namespace.gatekeeper_system,
    kubernetes_service_account.ratify,
    aws_iam_role_policy_attachment.ratify_ecr,
    aws_iam_role_policy.ratify_signer
  ]

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.ratify.metadata[0].name
  }

  values = [
    yamlencode({
      # AWS Signer root certificate for signature validation
      notationCerts = [
        file("${path.module}/files/aws-signer-notation-root.cert")
      ]
      # Explicit AWS environment variables for IRSA authentication
      extraEnv = [
        {
          name  = "AWS_REGION"
          value = var.region
        },
        {
          name  = "AWS_ROLE_ARN"
          value = aws_iam_role.ratify.arn
        },
        {
          name  = "AWS_WEB_IDENTITY_TOKEN_FILE"
          value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
        }
      ]
    })
  ]
  set {
    name  = "notation.enabled"
    value = "true"
  }
  set {
    name  = "featureFlags.RATIFY_EXPERIMENTAL_DYNAMIC_PLUGINS"
    value = "true"
  }

  set {
    name  = "featureFlags.RATIFY_CERT_ROTATION"
    value = "true"
  }
  set {
    name  = "oras.authProviders.awsEcrBasicEnabled"
    value = "true"
  }
}

# Note: While IRSA automatically injects AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE,
# we explicitly set them above (lines 181-186) for clarity and to ensure proper values.
# AWS_REGION must be set explicitly as IRSA doesn't provide it.
# IRSA is used instead of EKS Pod Identity because Ratify's ECR auth provider specifically
# requires the AWS_WEB_IDENTITY_TOKEN_FILE environment variable for authentication.

# Wait for Gatekeeper CRDs to be available
resource "null_resource" "wait_for_gatekeeper_crds" {
  depends_on = [helm_release.gatekeeper]

  provisioner "local-exec" {
    command = <<-EOT
      for i in {1..30}; do
        if kubectl get crd constrainttemplates.templates.gatekeeper.sh 2>/dev/null; then
          echo "Gatekeeper CRDs are ready"
          exit 0
        fi
        echo "Waiting for Gatekeeper CRDs... ($i/30)"
        sleep 2
      done
      echo "Timeout waiting for Gatekeeper CRDs"
      exit 1
    EOT
  }

  triggers = {
    gatekeeper_release = helm_release.gatekeeper.id
  }
}

# Wait for Ratify CRDs to be available
resource "null_resource" "wait_for_ratify_crds" {
  depends_on = [helm_release.ratify]

  provisioner "local-exec" {
    command = <<-EOT
      for i in {1..30}; do
        if kubectl get crd verifiers.config.ratify.deislabs.io 2>/dev/null; then
          echo "Ratify CRDs are ready"
          exit 0
        fi
        echo "Waiting for Ratify CRDs... ($i/30)"
        sleep 2
      done
      echo "Timeout waiting for Ratify CRDs"
      exit 1
    EOT
  }

  triggers = {
    ratify_release = helm_release.ratify.id
  }
}

resource "null_resource" "ratify_gatekeeper_template" {
  depends_on = [null_resource.wait_for_gatekeeper_crds]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: ratifyverification
spec:
  crd:
    spec:
      names:
        kind: RatifyVerification
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package ratifyverification

        # Get data from Ratify
        remote_data := response {
          images := [img | img = input.review.object.spec.containers[_].image]
          images_init := [img | img = input.review.object.spec.initContainers[_].image]
          images_ephemeral := [img | img = input.review.object.spec.ephemeralContainers[_].image]
          other_images := array.concat(images_init, images_ephemeral)
          all_images := array.concat(other_images, images)
          response := external_data({"provider": "ratify-provider", "keys": all_images})
        }

        # Base Gatekeeper violation
        violation[{"msg": msg}] {
          general_violation[{"result": msg}]
        }

        # Check if there are any system errors
        general_violation[{"result": result}] {
          err := remote_data.system_error
          err != ""
          result := sprintf("System error calling external data provider: %s", [err])
        }

        # Check if there are errors for any of the images
        general_violation[{"result": result}] {
          count(remote_data.errors) > 0
          result := sprintf("Error validating one or more images: %s", remote_data.errors)
        }

        # Check if the success criteria is true
        general_violation[{"result": result}] {
          subject_validation := remote_data.responses[_]
          subject_validation[1].isSuccess == false
          result := sprintf("Artifact failed verification: %s, \nreport: %v", [subject_validation[0], subject_validation[1]])
        }
YAML
    EOT
  }

  triggers = {
    gatekeeper_crds = null_resource.wait_for_gatekeeper_crds.id
  }
}

resource "null_resource" "ratify_gatekeeper_constraint" {
  depends_on = [null_resource.ratify_gatekeeper_template]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RatifyVerification
metadata:
  name: ratify-constraint
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["default"]
YAML
    EOT
  }

  triggers = {
    template = null_resource.ratify_gatekeeper_template.id
  }
}

resource "null_resource" "ratify_aws_signer_plugin" {
  depends_on = [null_resource.wait_for_ratify_crds]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Verifier
metadata:
  name: aws-signer-plugin
  namespace: gatekeeper-system
spec:
  name: notation-com.amazonaws.signer.notation.plugin
  artifactTypes: application/vnd.oci.image.manifest.v1+json
  source:
    artifact: public.ecr.aws/aws-signer/notation-plugin:linux-amd64-latest
YAML
    EOT
  }

  triggers = {
    ratify_crds = null_resource.wait_for_ratify_crds.id
  }
}

resource "null_resource" "ratify_certificate_store" {
  depends_on = [null_resource.wait_for_ratify_crds]

  provisioner "local-exec" {
    command = <<-EOT
      # Create CertificateStore CRD with AWS Signer root certificate
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: CertificateStore
metadata:
  name: ratify-notation-inline-cert-0
  namespace: gatekeeper-system
spec:
  provider: inline
  parameters:
    value: |
$(cat ${path.module}/files/aws-signer-notation-root.cert | sed 's/^/      /')
YAML
    EOT
  }

  triggers = {
    ratify_crds = null_resource.wait_for_ratify_crds.id
    cert_file   = filemd5("${path.module}/files/aws-signer-notation-root.cert")
  }
}

resource "null_resource" "ratify_notation_verifier" {
  depends_on = [
    null_resource.wait_for_ratify_crds,
    null_resource.ratify_aws_signer_plugin,
    null_resource.ratify_certificate_store,
    helm_release.ratify
  ]

  provisioner "local-exec" {
    environment = {
      SIGNER_PROFILE_ARN = aws_signer_signing_profile.eks_secure.arn
    }
    command = <<-EOT
      # Apply the Verifier with AWS Signer trust policy configuration
      # Uses signingAuthority trust store type (required for AWS Signer)
      kubectl apply -f - <<YAML
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Verifier
metadata:
  name: verifier-notation
  namespace: gatekeeper-system
spec:
  name: notation
  artifactTypes: application/vnd.cncf.notary.signature
  parameters:
    verificationCertStores:
      signingAuthority:
        certs:
          - ratify-notation-inline-cert-0
    trustPolicyDoc:
      version: "1.0"
      trustPolicies:
        - name: default
          registryScopes:
            - "*"
          signatureVerification:
            level: strict
          trustStores:
            - signingAuthority:certs
          trustedIdentities:
            - $SIGNER_PROFILE_ARN
YAML
    EOT
  }

  triggers = {
    ratify_crds         = null_resource.wait_for_ratify_crds.id
    aws_signer_plugin   = null_resource.ratify_aws_signer_plugin.id
    signing_profile_arn = aws_signer_signing_profile.eks_secure.arn
    certificate_store   = null_resource.ratify_certificate_store.id
    helm_release        = helm_release.ratify.id
    # Hash of the verifier config to detect trust policy changes
    verifier_config_hash = md5(jsonencode({
      trust_store_type   = "signingAuthority:certs"
      verification_level = "strict"
      registry_scopes    = ["*"]
    }))
  }
}

