resource "aws_iam_role" "github_ci" {
  name                 = "github-oidc-sns"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : aws_iam_openid_connect_provider.github.arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "ForAnyValue:StringLike" : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:${var.org}/*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_ci_sns" {
  name = "github-ci-create-sns"
  role = aws_iam_role.github_ci.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "CreateSnsTopic",
        "Effect" : "Allow",
        "Action" : [
          "sns:CreateTopic",
          "sns:TagResource"
        ],
        "Resource" : "*"
      },
      {
        "Sid": "AllowLoginToECR",
        "Effect": "Allow",
        "Action": [
            "ecr:GetAuthorizationToken"
        ],
        "Resource": "*"
      },
      {
        "Sid": "ECRPushAndList",
        "Effect": "Allow",
        "Action": [
            "ecr:BatchCheckLayerAvailability",
            "ecr:CompleteLayerUpload",
            "ecr:CreateRepository",
            "ecr:DescribeImages",
            "ecr:DescribeRepositories",
            "ecr:GetDownloadUrlForLayer",
            "ecr:InitiateLayerUpload",
            "ecr:PutImage",
            "ecr:UploadLayerPart"
        ],
        "Resource": "arn:aws:ecr:us-west-2:123456789012:repository/secure-demo"
      },
      {
            "Sid": "SignerPermissions",
            "Effect": "Allow",
            "Action": [
            "signer:StartSigningJob",
            "signer:GetSigningProfile",
            "signer:DescribeSigningJob"
            ],
            "Resource": [
                "arn:aws:signer:us-west-2:123456789012:/signing-profiles/ekssecureworkloads",
                "arn:aws:signer:us-west-2:123456789012:signing-jobs/*"
            ]
        }
    ]
  })
}

