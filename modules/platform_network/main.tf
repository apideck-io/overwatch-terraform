data "aws_vpc" "main" {
  tags = {
    Name = "platform-vpc-${var.stage}"
  }
}

data "aws_subnet" "main_private" {
  count = 3

  vpc_id = data.aws_vpc.main.id
  tags = {
    Name       = "platform-private-subnet-${count.index}-${var.stage}"
    SubnetType = "private"
  }
}

data "aws_subnet" "main_public" {
  count = 3

  vpc_id = data.aws_vpc.main.id
  tags = {
    Name       = "platform-public-subnet-${count.index}-${var.stage}"
    SubnetType = "public"
  }
}
