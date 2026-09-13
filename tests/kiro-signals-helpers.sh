#!/usr/bin/env bash
# tests/kiro-signals-helpers.sh - the vendor-surface predicates the kiro live
# drift guard asserts, factored so the portable suite drives the SAME logic with
# drifted samples. Each predicate takes an observed value and returns 0 or 1; it
# reads no pane and knows nothing about tmux, so a portable negative case can
# feed it a value the live tool is not currently producing.
#
# Callers must have sourced bin/fm-busy-lib.sh and bin/fm-composer-lib.sh: the
# busy predicates below delegate to the real fm_busy_lines_match rather than
# re-spelling any signature.

# fm_kiro_comm_is_anchored <foreground-command>
# 0 when the name is exactly what bin/fm-harness.sh and
# bin/fm-agent-process-lib.sh anchor on. A glob would defeat the anchoring those
# arms exist for, so this is an exact comparison.
fm_kiro_comm_is_anchored() {
  [ "${1-}" = kiro-cli ]
}

# fm_kiro_capture_has_resume_line: 0 when a captured screen carries the
# `--resume-id` flag kiro prints after /quit, which the adapter records as the
# resume contract. Consumes the capture on stdin.
fm_kiro_capture_has_resume_line() {
  grep -Fq -- '--resume-id'
}

# fm_kiro_composer_row_glyph_ok <row>
# 0 when the row's leading non-space character is kiro's `›` composer glyph. The
# shared classifier keys on that glyph through FM_COMPOSER_AGENT_PROMPT_GLYPHS,
# so a drift to any other character flips every bare-row kiro composer read from
# `empty` to `unknown` and defers every steer.
fm_kiro_composer_row_glyph_ok() {
  local row=${1-} first
  row=${row#"${row%%[![:space:]]*}"}
  first=${row%"${row#?}"}
  [ "$first" = '›' ]
}

# fm_kiro_footer_busy [harness]
# 0 when a captured screen reads busy through the real delivery matcher.
# Consumes the capture on stdin and folds it the way every production caller
# does - blank rows dropped, last 12 kept - so a footer left behind in scrollback
# cannot satisfy the match. With no argument this is the harness-less union the
# tmux submit core reads; with `kiro` it is the per-harness signature.
fm_kiro_footer_busy() {
  local harness=${1-} visible
  visible=$(grep -v '^[[:space:]]*$' | tail -12)
  printf '%s\0' "$visible" | fm_busy_lines_match "$harness"
}
