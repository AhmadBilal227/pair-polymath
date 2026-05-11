#!/usr/bin/env bats
# Path containment: the planner-picked file path must resolve inside cwd or be rejected.
# The check is inlined in bin/statusline.sh (case "$file_real" in "$repo_real"/*) ...).
# Until M3 extracts a reusable helper, this file is a placeholder so the bats harness
# is wired up end-to-end.

@test "containment: placeholder until M3 extracts helper" {
  skip "containment helper extraction deferred to M3"
}
