#!/usr/bin/env bats
# End-to-end smoke: bin/statusline.sh must exit 0 on a variety of stdin shapes.

@test "statusline.sh: exits 0 with sample stdin" {
  run bash -c "cat '${BATS_TEST_DIRNAME}/fixtures/stdin-sample.json' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "statusline.sh: handles missing session_id" {
  run bash -c "echo '{}' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
}

@test "statusline.sh: handles malformed JSON gracefully" {
  run bash -c "echo 'not-json' | bash '${BATS_TEST_DIRNAME}/../bin/statusline.sh'"
  [ "$status" -eq 0 ]
}
