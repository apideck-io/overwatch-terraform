data "aws_vpc" "main" {
  tags = {
    Name = "apideck--vpc--${var.stage}"
  }
}

data "aws_subnet" "main_private" {
  count = 3

  vpc_id = data.aws_vpc.main.id
  tags = {
    Name       = "apideck--vpc--${var.stage}-private-subnet-${count.index}"
    SubnetType = "private"
  }
}

data "aws_subnet" "main_public" {
  count = 3

  vpc_id = data.aws_vpc.main.id
  tags = {
    Name       = "apideck--vpc--${var.stage}-public-subnet-${count.index}"
    SubnetType = "public"
  }
}
