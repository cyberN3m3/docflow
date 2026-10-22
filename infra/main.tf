# The DocFlow environment. Modules are added phase by phase:
#   Phase 3: network, storage, database, queue
#   Phase 5: compute, edge
#   Phase 10: monitoring

data "aws_caller_identity" "current" {}
