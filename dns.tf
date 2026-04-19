data "aws_route53_zone" "main" {
    name         = "ekstest.com."
    private_zone = false
  }

  output "zone_id" {
    value = data.aws_route53_zone.main.zone_id
  }

  output "name_servers" {
    value = data.aws_route53_zone.main.name_servers
  }