# Secrets Manager secret + rotation Lambda for a Neon Postgres user.
# Rotation itself is turned on in the video with `aws secretsmanager rotate-secret`.
terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" { region = var.region }

variable "region" { default = "eu-west-1" }
variable "db_host" { description = "Neon endpoint, e.g. ep-cool-name-123456.eu-central-1.aws.neon.tech" }
variable "db_password" {
  description = "Initial password of the app role (setup.sh creates the role with it)"
  sensitive   = true
}

data "aws_caller_identity" "me" {}

# --- the secret --------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name                    = "rotation-demo/app-db"
  recovery_window_in_days = 0 # demo: delete right away on destroy
}

resource "aws_secretsmanager_secret_version" "initial" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "postgres", host = var.db_host, port = 5432,
    username = "app", password = var.db_password, dbname = "neondb"
  })
  lifecycle { ignore_changes = [secret_string] } # rotation owns the value after day one
}

# --- the rotation function ---------------------------------------------------
data "archive_file" "rotator" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/build" # rotate.py + pg8000, filled by setup.sh
  output_path = "${path.module}/rotator.zip"
}

resource "aws_iam_role" "rotator" {
  name = "secret-rotator"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rotator" {
  name = "rotate-secret"
  role = aws_iam_role.rotator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      { Effect = "Allow", Action = "secretsmanager:GetRandomPassword", Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "rotator" {
  function_name    = "secret-rotator"
  role             = aws_iam_role.rotator.arn
  runtime          = "python3.12"
  handler          = "rotate.lambda_handler"
  filename         = data.archive_file.rotator.output_path
  source_code_hash = data.archive_file.rotator.output_base64sha256
  timeout          = 30
}

# Secrets Manager may invoke it, but only for secrets in this account (confused deputy).
resource "aws_lambda_permission" "secretsmanager" {
  function_name  = aws_lambda_function.rotator.function_name
  action         = "lambda:InvokeFunction"
  principal      = "secretsmanager.amazonaws.com"
  source_account = data.aws_caller_identity.me.account_id
}

output "lambda_arn" { value = aws_lambda_function.rotator.arn }
