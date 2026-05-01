output "mysql_root_password_secret_arn" {
  description = "ARN of MySQL root password secret"
  value       = aws_secretsmanager_secret.mysql_root_password.arn
}

output "mysql_app_password_secret_arn" {
  description = "ARN of MySQL app user password secret"
  value       = aws_secretsmanager_secret.mysql_app_password.arn
}

output "ecr_repository_urls" {
  description = "Map of repository names to URLs"
  value       = { for k, v in module.ecr : k => v.repository_url }
}

output "ecr_repository_arns" {
  description = "Map of repository names to ARNs"
  value       = { for k, v in module.ecr : k => v.repository_arn }
}

output "appconfig_application_id" {
  description = "AppConfig Application ID"
  value       = aws_appconfig_application.main.id
}

output "appconfig_environment_id" {
  description = "AppConfig Environment ID"
  value       = aws_appconfig_environment.main.environment_id
}

output "appconfig_profile_id" {
  description = "AppConfig Configuration Profile ID"
  value       = aws_appconfig_configuration_profile.deployment_manifest.configuration_profile_id
}

output "appconfig_deployment_strategy_id" {
  description = "AppConfig Deployment Strategy ID"
  value       = aws_appconfig_deployment_strategy.immediate.id
}

output "initial_config_version" {
  description = "Initial AppConfig configuration version number"
  value       = aws_appconfig_hosted_configuration_version.initial.version_number
}

output "summary" {
  description = "Summary of bootstrap resources"
  value = <<-EOT
    Bootstrap Resources Created:
    
    Secrets Manager:
      - MySQL Root Password: ${aws_secretsmanager_secret.mysql_root_password.arn}
      - MySQL App Password:  ${aws_secretsmanager_secret.mysql_app_password.arn}
    
    ECR Repositories:
      ${join("\n      ", [for k, v in module.ecr : "- ${k}: ${v.repository_url}"])}
    
    AppConfig:
      - Application ID: ${aws_appconfig_application.main.id}
      - Environment ID: ${aws_appconfig_environment.main.environment_id}
      - Profile ID:     ${aws_appconfig_configuration_profile.deployment_manifest.configuration_profile_id}
      - Strategy ID:    ${aws_appconfig_deployment_strategy.immediate.id}
      - Initial Config Version: ${aws_appconfig_hosted_configuration_version.initial.version_number}
    
    GitHub Secrets to Add:
      APPCONFIG_APPLICATION_ID=${aws_appconfig_application.main.id}
      APPCONFIG_ENVIRONMENT_ID=${aws_appconfig_environment.main.environment_id}
      APPCONFIG_PROFILE_ID=${aws_appconfig_configuration_profile.deployment_manifest.configuration_profile_id}
      APPCONFIG_DEPLOYMENT_STRATEGY_ID=${aws_appconfig_deployment_strategy.immediate.id}
    
    Next Steps:
      1. Add the GitHub secrets above to your repository
      2. Push initial Docker images to ECR (or let CI/CD do it)
      3. Run: cd ../infrastructure && terraform init
      4. Update terraform.tfvars with the secret ARNs above
      5. Run: terraform apply
      
    Note: Initial AppConfig manifest (version ${aws_appconfig_hosted_configuration_version.initial.version_number}) created with placeholder images.
          CI/CD will update this with actual image tags on first build.
  EOT
}
