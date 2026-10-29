# Resources that gained `count` (var.enable_bastion and the wait_for_* variables)
# keep their existing state: a deployment made before the change has these as
# un-indexed instances, which move to index [0] instead of being recreated. Safe to
# delete once every deployment of this template has been applied once.

moved {
  from = aws_iam_role.bastion
  to   = aws_iam_role.bastion[0]
}

moved {
  from = aws_iam_role_policy_attachment.bastion_ssm
  to   = aws_iam_role_policy_attachment.bastion_ssm[0]
}

moved {
  from = aws_iam_role_policy.bastion_read_ssh_key
  to   = aws_iam_role_policy.bastion_read_ssh_key[0]
}

moved {
  from = aws_iam_role_policy.bastion_read_ca
  to   = aws_iam_role_policy.bastion_read_ca[0]
}

moved {
  from = aws_iam_role_policy.bastion_describe_aig
  to   = aws_iam_role_policy.bastion_describe_aig[0]
}

moved {
  from = aws_iam_role_policy.bastion_report_aig_ready
  to   = aws_iam_role_policy.bastion_report_aig_ready[0]
}

moved {
  from = aws_iam_instance_profile.bastion
  to   = aws_iam_instance_profile.bastion[0]
}

moved {
  from = aws_security_group.bastion
  to   = aws_security_group.bastion[0]
}

moved {
  from = aws_security_group_rule.dlpod_from_bastion
  to   = aws_security_group_rule.dlpod_from_bastion[0]
}

moved {
  from = aws_security_group_rule.dlpod_ssh_from_bastion
  to   = aws_security_group_rule.dlpod_ssh_from_bastion[0]
}

moved {
  from = aws_security_group_rule.bastion_ssh_from_dlpod
  to   = aws_security_group_rule.bastion_ssh_from_dlpod[0]
}

moved {
  from = aws_security_group_rule.guardrails_from_bastion
  to   = aws_security_group_rule.guardrails_from_bastion[0]
}

moved {
  from = aws_security_group_rule.guardrails_ssh_from_bastion
  to   = aws_security_group_rule.guardrails_ssh_from_bastion[0]
}

moved {
  from = aws_security_group_rule.aig_ssh_from_bastion
  to   = aws_security_group_rule.aig_ssh_from_bastion[0]
}

moved {
  from = aws_security_group_rule.aig_config_api_from_bastion
  to   = aws_security_group_rule.aig_config_api_from_bastion[0]
}

moved {
  from = aws_instance.bastion
  to   = aws_instance.bastion[0]
}

moved {
  from = aws_ssm_parameter.aig_ready
  to   = aws_ssm_parameter.aig_ready[0]
}

moved {
  from = null_resource.aig_ready
  to   = null_resource.aig_ready[0]
}

moved {
  from = aws_secretsmanager_secret.ca_key
  to   = aws_secretsmanager_secret.ca_key[0]
}

moved {
  from = aws_secretsmanager_secret_version.ca_key
  to   = aws_secretsmanager_secret_version.ca_key[0]
}

moved {
  from = aws_secretsmanager_secret.ca_cert
  to   = aws_secretsmanager_secret.ca_cert[0]
}

moved {
  from = aws_secretsmanager_secret_version.ca_cert
  to   = aws_secretsmanager_secret_version.ca_cert[0]
}

moved {
  from = null_resource.guardrails_ready
  to   = null_resource.guardrails_ready[0]
}

moved {
  from = null_resource.dlpod_ready
  to   = null_resource.dlpod_ready[0]
}

moved {
  from = aws_secretsmanager_secret.ssh_private_key
  to   = aws_secretsmanager_secret.ssh_private_key[0]
}

moved {
  from = aws_secretsmanager_secret_version.ssh_private_key
  to   = aws_secretsmanager_secret_version.ssh_private_key[0]
}
