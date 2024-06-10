resource "local_file" "test" {
  filename = "${path.module}/test.txt"
  content  = "Hello world2!"
}

resource "null_resource" "null1" {}
