import std/[os, tempfiles, unittest]
import datpkgr/config
import datpkgr/operations
import datpkgr/types
import helpers

var submodCalls {.threadvar.}: seq[string]
var capturedLog {.threadvar.}: seq[string]

proc recordSubmod(name, dest: string) {.gcsafe.} =
  submodCalls.add(name & "|" & dest)

proc recordLog(level: LogLevel, msg: string) {.gcsafe.} =
  capturedLog.add(msg)

suite "operations — pkgNameFromUrl":
  test "github https url":
    check pkgNameFromUrl("https://github.com/openpeeps/spry") == "spry"
    check pkgNameFromUrl("https://github.com/openpeeps/spry.git") == "spry"

  test "scp-like ssh url":
    check pkgNameFromUrl("git@github.com:openpeeps/spry.git") == "spry"

  test "git+ and ssh:// urls":
    check pkgNameFromUrl("git+https://github.com/openpeeps/spry.git") == "spry"
    check pkgNameFromUrl("ssh://git@github.com/openpeeps/spry.git") == "spry"

  test "ref and query suffixes are stripped":
    check pkgNameFromUrl("https://github.com/openpeeps/spry#master") == "spry"
    check pkgNameFromUrl("https://github.com/openpeeps/spry?ref=main") == "spry"

  test "url with a path deeper than owner/repo takes the last segment":
    check pkgNameFromUrl("https://github.com/openpeeps/awesome/spry") == "spry"

suite "operations — parseFeatureFlags":
  test "splits comma-separated flags and strips whitespace":
    check parseFeatureFlags("ssl,jwt") == @["ssl", "jwt"]
    check parseFeatureFlags("ssl, jwt, async") == @["ssl", "jwt", "async"]

  test "empty input yields no flags":
    check parseFeatureFlags("") == newSeq[string]()
    check parseFeatureFlags(",") == newSeq[string]()

suite "operations — isGitUrl":
  test "recognises git urls":
    check isGitUrl("https://github.com/openpeeps/spry")
    check isGitUrl("http://github.com/openpeeps/spry")
    check isGitUrl("git@github.com:openpeeps/spry.git")
    check isGitUrl("git+https://github.com/openpeeps/spry")
    check isGitUrl("ssh://git@github.com/openpeeps/spry.git")

  test "rejects plain package names":
    check not isGitUrl("spry")
    check not isGitUrl("spry@1.2.0")
    check not isGitUrl("/usr/local/spry")

suite "operations — pluralize":
  test "singular for 1, plural otherwise":
    check pluralize(1, "version") == "version"
    check pluralize(0, "version") == "versions"
    check pluralize(2, "version") == "versions"
    check pluralize(10, "package") == "packages"

suite "operations — depName":
  test "uses name when present, else url basename":
    check depName(PkgDependency(name: "spry", url: "")) == "spry"
    check depName(PkgDependency(name: "", url: "https://github.com/openpeeps/spry.git")) == "spry"
    check depName(PkgDependency(name: "", url: "")) == ""

suite "operations — isRecordRoot":
  test "normal install records only the requested package as root":
    check isRecordRoot("tim", "tim", false, @[]) == true
    check isRecordRoot("datpkgr", "tim", false, @[]) == false

  test "depsOnly skips the root and marks its direct deps as roots":
    check isRecordRoot("tim", "tim", true, @["datpkgr"]) == false
    check isRecordRoot("datpkgr", "tim", true, @["datpkgr"]) == true
    check isRecordRoot("malebolgia", "tim", true, @["datpkgr"]) == false

  test "depsOnly with no direct deps records nothing as root":
    check isRecordRoot("tim", "tim", true, @[]) == false

suite "operations — notifySubmodules":
  test "destHasSubmodules reflects .gitmodules presence":
    let dir = createTempDir("datpkgr_sub_", "")
    defer: removeDir(dir)
    check not destHasSubmodules(dir)
    writeFile(dir / ".gitmodules", "[submodule \"vendor/child\"]\n")
    check destHasSubmodules(dir)

  test "fires onSubmodules when enabled and .gitmodules present":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.allowSubmodules = true
    cfg.callbacks.onSubmodules = recordSubmod
    let dir = createTempDir("datpkgr_sub_", "")
    defer: removeDir(dir)
    writeFile(dir / ".gitmodules", "[submodule \"vendor/child\"]\n")
    submodCalls = @[]
    cfg.notifySubmodules("zlib", dir)
    check submodCalls == @["zlib|" & dir]

  test "silent when disabled or without .gitmodules":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.allowSubmodules = true
    cfg.callbacks.onSubmodules = recordSubmod
    let bare = createTempDir("datpkgr_sub_", "")
    defer: removeDir(bare)
    submodCalls = @[]
    cfg.notifySubmodules("zlib", bare)
    check submodCalls.len == 0
    let withSub = createTempDir("datpkgr_sub_", "")
    defer: removeDir(withSub)
    writeFile(withSub / ".gitmodules", "[submodule \"vendor/child\"]\n")
    cfg.allowSubmodules = false
    cfg.notifySubmodules("zlib", withSub)
    check submodCalls.len == 0

  test "falls back to indented log line without callback":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.allowSubmodules = true
    cfg.callbacks.onSubmodules = nil
    cfg.callbacks.log = recordLog
    let dir = createTempDir("datpkgr_sub_", "")
    defer: removeDir(dir)
    writeFile(dir / ".gitmodules", "[submodule \"vendor/child\"]\n")
    capturedLog = @[]
    cfg.notifySubmodules("zlib", dir)
    check capturedLog == @["    Installing with submodules"]
