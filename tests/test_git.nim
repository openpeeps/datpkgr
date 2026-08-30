import std/[unittest, strtabs, strutils]
import datpkgr/git

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
