output "queue_name" {
  value = aws_sqs_queue.jobs.name
}

output "queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "queue_arn" {
  value = aws_sqs_queue.jobs.arn
}

output "dead_letter_queue_arn" {
  value = aws_sqs_queue.dead_letter.arn
}

output "dead_letter_queue_name" {
  value = aws_sqs_queue.dead_letter.name
}
