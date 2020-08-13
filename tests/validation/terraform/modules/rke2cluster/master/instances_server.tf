resource "aws_instance" "master" {
  ami           =  var.aws_ami
  instance_type =  var.ec2_instance_class
  connection {
    type        = "ssh"
    user        = "${var.aws_user}"
    host        = self.public_ip
    private_key = "${file(var.access_key)}"
  }
  subnet_id = var.subnets
  availability_zone = var.availability_zone
  vpc_security_group_ids = ["${var.sg_id}"]

  key_name = var.key_name
  tags = {
    Name = "${var.resource_name}-rke2-server"
  }

  provisioner "file" {
    source      = "install_rke2_on_first_node.sh"
    destination = "/tmp/install_rke2_on_first_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install_rke2_on_first_node.sh",
      "sudo /tmp/install_rke2_on_first_node.sh ${var.ctype} ${var.username} ${var.password} ${aws_route53_record.aws_route53.fqdn} ${var.rke2_version}",
      "sudo curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl",
      "sleep 60",
      "sudo chmod u+x kubectl",
      "sudo mv kubectl /usr/local/bin",
    ]
  }

  provisioner "local-exec" {
    command = "echo ${aws_instance.master.public_ip} >/tmp/${var.resource_name}_master_ip"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/nodetoken /tmp/${var.resource_name}_nodetoken"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/config /tmp/${var.resource_name}_config"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/joinflags /tmp/${var.resource_name}_joinflags"
  }
  provisioner "local-exec" {
    command = "sed s/127.0.0.1/\"${aws_route53_record.aws_route53.fqdn}\"/g /tmp/${var.resource_name}_config >/tmp/${var.resource_name}_kubeconfig"
  }
}

resource "aws_instance" "master2" {
  ami           =  var.aws_ami
  instance_type =  var.ec2_instance_class
  count         = var.no_of_server_nodes_to_join
  connection {
    type        = "ssh"
    user        = "${var.aws_user}"
    host        = self.public_ip
    private_key = "${file(var.access_key)}"
  }
  root_block_device {
    volume_size = "20"
    volume_type = "standard"
  }

  subnet_id = var.subnets
  availability_zone = var.availability_zone
  vpc_security_group_ids = ["${var.sg_id}"]

  key_name = var.key_name
  tags = {
    Name = "${var.resource_name}-rke2-servers"
  }
  depends_on       = ["aws_instance.master"]

  provisioner "file" {
    source      = "join_master.sh"
    destination = "/tmp/join_master.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join_master.sh",
      "sudo /tmp/join_master.sh ${var.ctype} ${var.username} ${var.password} ${aws_route53_record.aws_route53.fqdn} ${aws_instance.master.public_ip} ${local.node_token} ${var.rke2_version}",
      "sudo curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl",
      "sleep 60",
      "sudo chmod u+x kubectl",
      "sudo mv kubectl /usr/local/bin",

    ]
  }
}

data "local_file" "token" {
  filename = "/tmp/${var.resource_name}_nodetoken"
  depends_on = ["aws_instance.master"]
}

locals {
  node_token = trimspace("${data.local_file.token.content}")
}

resource "aws_lb_target_group" "aws_tg_6443" {
  port             = 6443
  protocol         = "TCP"
  vpc_id           = "${var.vpc_id}"
  name             = "${var.resource_name}-rke2-tg"
}

resource "aws_lb_target_group" "aws_tg_9345" {
  port             = 9345
  protocol         = "TCP"
  vpc_id           = "${var.vpc_id}"
  name             = "${var.resource_name}-rke2-9345-tg"
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_6443" {
  target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  target_id        = "${aws_instance.master.id}"
  port             = 6443
  depends_on       = ["aws_lb_target_group.aws_tg_6443"]
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_6443_2" {
  target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  count            = length(aws_instance.master2)
  target_id        = "${aws_instance.master2[count.index].id}"
  port             = 6443
  depends_on       = ["aws_lb_target_group.aws_tg_6443"]
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_9345" {
  target_group_arn = "${aws_lb_target_group.aws_tg_9345.arn}"
  target_id        = "${aws_instance.master.id}"
  port             = 9345
  depends_on       = ["aws_lb_target_group.aws_tg_9345"]
}
resource "aws_lb_target_group_attachment" "aws_tg_attachment_9345_2" {
  target_group_arn = "${aws_lb_target_group.aws_tg_9345.arn}"
  count            = length(aws_instance.master2)
  target_id        = "${aws_instance.master2[count.index].id}"
  port             = 9345
  depends_on       = ["aws_lb_target_group.aws_tg_9345"]
}


resource "aws_lb" "aws_nlb" {
  internal           = false
  load_balancer_type = "network"
  subnets            = ["${var.subnets}"]
  name               = "${var.resource_name}-rke2-nlb"
}

resource "aws_lb_listener" "aws_nlb_listener_6443" {
  load_balancer_arn = "${aws_lb.aws_nlb.arn}"
  port              = "6443"
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  }
}

resource "aws_lb_listener" "aws_nlb_listener_9345" {
  load_balancer_arn = "${aws_lb.aws_nlb.arn}"
  port              = "9345"
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.aws_tg_9345.arn}"
  }
}
resource "aws_route53_record" "aws_route53" {
  zone_id            = "${data.aws_route53_zone.selected.zone_id}"
  name               = "${var.resource_name}-rke2-route53"
  type               = "CNAME"
  ttl                = "300"
  records            = ["${aws_lb.aws_nlb.dns_name}"]
  depends_on         = ["aws_lb_listener.aws_nlb_listener_6443"]
}

data "aws_route53_zone" "selected" {
  name               = "${var.qa_space}"
  private_zone       = false
}

resource "null_resource" "update_kubeconfig" {
  provisioner "local-exec" {
    command = "sed s/127.0.0.1/\"${aws_route53_record.aws_route53.fqdn}\"/g /tmp/\"${var.resource_name}_config\" >/tmp/${var.resource_name}_kubeconfig"
  }
  depends_on = ["aws_instance.master"]
}

resource "null_resource" "store_fqdn" {
  provisioner "local-exec" {
    command = "echo \"${aws_route53_record.aws_route53.fqdn}\" >/tmp/${var.resource_name}_fixed_reg_addr"
  }
  depends_on = ["aws_instance.master"]
}