resource "local_file" "test" {
  filename = "${path.module}/test.txt"
  content  = "Hello world!"
}

resource "null_resource" "null1" {}
