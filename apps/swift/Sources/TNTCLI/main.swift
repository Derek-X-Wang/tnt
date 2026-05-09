// TNTCLI — the bundled `tnt` binary. Worker Agents call this to push
// Session Events into the Local Ingest endpoint inside the Desktop App.
// v0 verbs (event/vocab/pref) land in milestone M2; this is the skeleton.

import Foundation

let version = "0.0.0-skeleton"
let usage = """
tnt \(version) — Personal Master Agent CLI (skeleton)

Verbs land in milestone M2:
  event started|stopped|summary|blocked|error
  vocab add|list|remove
  pref  get|set

For now this binary only prints its version and usage so the workspace
build target is exercised end-to-end.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--version" || arguments.first == "-v" {
    print(version)
    exit(0)
}

print(usage)
exit(0)
