import std/[unittest, strtabs, strutils, os, osproc, tempfiles]
import datpkgr/git
import datpkgr/config

suite "git — toGitSshUrl":
  test "https URL becomes scp-like ssh url with .git suffix":
    check toGitSshUrl("https://github.com/openpeeps/clue") ==
      "git@github.com:openpeeps/clue.git"
    check toGitSshUrl("https://github.com/openpeeps/clue.git") ==
      "git@github.com:openpeeps/clue.git"

  test "git+https strips the git+ prefix":
    check toGitSshUrl("git+https://github.com/openpeeps/clue") ==
      "git@github.com:openpeeps/clue.git"

  test "http scheme is translated too":
    check toGitSshUrl("http://example.com/org/repo") ==
      "git@example.com:org/repo.git"

  test "non-http URLs pass through unchanged":
    check toGitSshUrl("git@github.com:openpeeps/clue.git") ==
      "git@github.com:openpeeps/clue.git"
    check toGitSshUrl("ssh://git@github.com/org/repo") ==
      "ssh://git@github.com/org/repo"

  test "url with no path returns unchanged":
    check toGitSshUrl("https://example.com") == "https://example.com"

  test "branch ref suffix is not part of url translation":
    # toGitSshUrl is called on url without #ref; pkgNameFromUrl strips it
    check toGitSshUrl("https://github.com/org/repo") ==
      "git@github.com:org/repo.git"

suite "git — gitEnv":
  test "contains GIT_SSH_COMMAND":
    let env = gitEnv()
    check "GIT_SSH_COMMAND" in env
    check "BatchMode" in env["GIT_SSH_COMMAND"]

  test "nonInteractive sets GIT_TERMINAL_PROMPT=0":
    let env = gitEnv(nonInteractive = true)
    check env["GIT_TERMINAL_PROMPT"] == "0"
    let env2 = gitEnv(nonInteractive = false)
    check not ("GIT_TERMINAL_PROMPT" in env2) or env2["GIT_TERMINAL_PROMPT"] != "0"

proc makeSubmoduleFixture(): tuple[parent, base: string] =
  ## Local parent repo with a `vendor/child` submodule (file-protocol).
  let base = createTempDir("datpkgr_submod_", "")
  let child = base / "child"
  let parent = base / "parent"
  createDir(child)
  createDir(parent)
  proc git(dir: string, args: string) =
    let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " " & args)
    check code == 0
  for d in [child, parent]:
    discard execCmdEx("git init -q " & quoteShell(d))
    git(d, "config user.email t@t.t")
    git(d, "config user.name t")
  writeFile(child / "data.txt", "hello\n")
  git(child, "add -A")
  git(child, "commit -qm init")
  writeFile(parent / "readme.txt", "parent\n")
  git(parent, "add -A")
  git(parent, "commit -qm init")
  let (addOut, addCode) = execCmdEx("git -C " & quoteShell(parent) &
    " -c protocol.file.allow=always submodule add -q " &
    quoteShell(child) & " vendor/child")
  check addCode == 0
  git(parent, "commit -qm addsub")
  (parent, base)

suite "git — ssh host cache":
  test "sshHostOf extracts the host from http(s) urls":
    check sshHostOf("https://github.com/openpeeps/clue") == "github.com"
    check sshHostOf("http://example.com/org/repo") == "example.com"
    check sshHostOf("git+https://github.com/openpeeps/clue") == "github.com"

  test "sshHostOf returns empty when no ssh attempt exists":
    check sshHostOf("git@github.com:openpeeps/clue.git") == ""
    check sshHostOf("ssh://git@github.com/org/repo") == ""
    check sshHostOf("https://example.com") == ""
    check sshHostOf("/local/path/repo") == ""

  test "known-bad hosts are remembered per process":
    check not sshKnownBad("sshnofail.invalid")
    markSshBad("sshnofail.invalid")
    check sshKnownBad("sshnofail.invalid")
    check not sshKnownBad("other.invalid")

  test "empty host is a no-op":
    markSshBad("")
    check not sshKnownBad("")

  test "refresh with known-bad ssh host goes straight to plain url":
    let (parent, base) = makeSubmoduleFixture()
    defer: removeDir(base)
    let cfg = newDatpkgrConfig("sshskiptest", base / "root-skip")
    let dest = base / "clone-skip"
    check cfg.cloneRepo(parent, dest, nonInteractive = true)
    markSshBad("refreshskip.invalid")
    check not cfg.refreshRemoteTags(dest,
      "https://refreshskip.invalid/org/repo", nonInteractive = true)

suite "git — submodules (opt-in via allowSubmodules)":
  test "disabled by default: submodule content absent":
    let (parent, base) = makeSubmoduleFixture()
    defer: removeDir(base)
    let cfg = newDatpkgrConfig("submodtest", base / "root-off")
    check not cfg.allowSubmodules
    let dest = base / "clone-off"
    check cfg.cloneRepo(parent, dest, nonInteractive = true)
    check fileExists(dest / ".gitmodules")
    check not fileExists(dest / "vendor" / "child" / "data.txt")

  test "enabled: clone fetches submodule content":
    let (parent, base) = makeSubmoduleFixture()
    defer: removeDir(base)
    let cfg = newDatpkgrConfig("submodtest", base / "root-on",
      allowSubmodules = true)
    let dest = base / "clone-on"
    check cfg.cloneRepo(parent, dest, nonInteractive = true)
    check fileExists(dest / "vendor" / "child" / "data.txt")

  test "enabled: checkout heals a stale cache cloned without submodules":
    let (parent, base) = makeSubmoduleFixture()
    defer: removeDir(base)
    let cfgOff = newDatpkgrConfig("submodtest", base / "root-heal",
      allowSubmodules = false)
    let dest = base / "clone-heal"
    check cfgOff.cloneRepo(parent, dest, nonInteractive = true)
    check not fileExists(dest / "vendor" / "child" / "data.txt")
    let cfgOn = newDatpkgrConfig("submodtest", base / "root-heal",
      allowSubmodules = true)
    check cfgOn.checkoutHead(dest)
    check fileExists(dest / "vendor" / "child" / "data.txt")

  test "raw checkout honors explicit allowSubmodules flag":
    let (parent, base) = makeSubmoduleFixture()
    defer: removeDir(base)
    let cfg = newDatpkgrConfig("submodtest", base / "root-raw")
    let dest = base / "clone-raw"
    check cfg.cloneRepo(parent, dest, nonInteractive = true)
    check not fileExists(dest / "vendor" / "child" / "data.txt")
    check checkoutHeadRaw(dest, allowSubmodules = true)
    check fileExists(dest / "vendor" / "child" / "data.txt")
