# recovery-tools.sh -- aggregator.
#
# The helpers are split by category into sibling files; this file just sources
# them in dependency order. build-microg-ota.sh copies all of shared/*.sh into
# each package, and the installers keep sourcing this single entry point.
#
# Order matters: output.sh defines ui_print (used by everything), partitions.sh
# defines abort (used by detect.sh / native-libs.sh), and microg-defs.sh's
# print_banner needs ui_print/center_text from output.sh.
#
# Use ./ -- recovery's shell (mksh) treats a slash-less `.` arg as a PATH
# lookup, and cwd is not in PATH, so `. output.sh` would fail to find it.
. ./output.sh
. ./partitions.sh
. ./detect.sh
. ./native-libs.sh
. ./microg-defs.sh
