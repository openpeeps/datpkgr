# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[os, osproc, strutils, sets, locks, monotimes, strtabs, options]
import pkg/threading/semaphore
import ./config

const MaxConcurrentGit* = 8

var gitSemaphore* = createSemaphore(MaxConcurrentGit)

var failedClones* = initHashSet[string]()
var failedClonesLock*: Lock
failedClonesLock.initLock()

proc gitEnv*(nonInteractive = false): StringTableRef =
  result = newStringTable()
  for k, v in envPairs():
    result[k] = v
  result["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=10"
  if nonInteractive:
    result["GIT_TERMINAL_PROMPT"] = "0"

proc gitExec*(cfg: DatpkgrConfig, cmd: string, env: StringTableRef = nil): tuple[output: string, exitCode: int] {.gcsafe.} =
  var e = env
  if e == nil:
    e = gitEnv()
  gitSemaphore.wait()
  defer: gitSemaphore.signal()
  when defined(posix):
    let tmpOut = getTempDir() / ("datpkg_git_" & $getCurrentProcessId() &
      "_" & $getMonoTime().ticks & ".out")
    var p = startProcess(cmd & " > " & quoteShell(tmpOut) & " 2>&1",
      env = e, options = {poEvalCommand, poParentStreams, poUsePath})
    result.exitCode = p.waitForExit()
    p.close()
    if fileExists(tmpOut):
      result.output = readFile(tmpOut)
      removeFile(tmpOut)
  else:
    result = execCmdEx(cmd, env = e)
  if cfg.debugEnabled:
    cfg.logDebug("$ " & cmd)
    cfg.logDebug("  -> exit " & $result.exitCode)

proc gitExecRaw*(cmd: string, env: StringTableRef = nil): tuple[output: string, exitCode: int] {.gcsafe.} =
  var e = env
  if e == nil:
    e = gitEnv()
  gitSemaphore.wait()
  defer: gitSemaphore.signal()
  when defined(posix):
    let tmpOut = getTempDir() / ("datpkg_git_" & $getCurrentProcessId() &
      "_" & $getMonoTime().ticks & ".out")
    var p = startProcess(cmd & " > " & quoteShell(tmpOut) & " 2>&1",
      env = e, options = {poEvalCommand, poParentStreams, poUsePath})
    result.exitCode = p.waitForExit()
    p.close()
    if fileExists(tmpOut):
      result.output = readFile(tmpOut)
      removeFile(tmpOut)
  else:
    result = execCmdEx(cmd, env = e)

proc gitExecLegacy*(cmd: string, env: StringTableRef = nil): tuple[output: string, exitCode: int] {.gcsafe.} =
  gitExecRaw(cmd, env)

proc toGitSshUrl*(url: string): string =
  var u = url.strip()
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if not (u.startsWith("https://") or u.startsWith("http://")):
    return u
  let slashPos = u.split("://")[1].find('/')
  if slashPos < 0:
    return u
  let host = u.split("://")[1][0 ..< slashPos]
  var path = u.split("://")[1][slashPos + 1 .. ^1]
  if not path.endsWith(".git"):
    path.add(".git")
  result = "git@" & host & ":" & path

proc cloneRepo*(cfg: DatpkgrConfig, url, dest: string, nonInteractive = false): bool {.gcsafe.} =
  let env = gitEnv(nonInteractive)
  let (o1, c1) = cfg.gitExec("git clone " & toGitSshUrl(url) & " " & dest, env = env)
  if c1 == 0:
    discard cfg.gitExec("git -C " & dest & " fetch --tags --quiet", env = env)
    return true
  let (o2, c2) = cfg.gitExec("git clone " & url & " " & dest, env = env)
  if c2 == 0:
    discard cfg.gitExec("git -C " & dest & " fetch --tags --quiet", env = env)
    return true
  false

proc refreshRemoteTags*(cfg: DatpkgrConfig, dest, url: string, nonInteractive = false): bool {.gcsafe.} =
  discard cfg.gitExec("git -C " & dest & " remote set-url origin " & toGitSshUrl(url))
  let env = gitEnv(nonInteractive)
  let (output, exitCode) = cfg.gitExec("git -C " & dest &
    " fetch --tags --prune --quiet", env = env)
  if exitCode != 0:
    discard cfg.gitExec("git -C " & dest & " remote set-url origin " & url)
    let (out2, code2) = cfg.gitExec("git -C " & dest &
      " fetch --tags --prune --quiet", env = env)
    if code2 != 0:
      return false
  true

proc clonePackage*(cfg: DatpkgrConfig, url, dest: string, refresh = false, nonInteractive = false): bool =
  withLock failedClonesLock:
    if dest in failedClones:
      return false
  if dirExists(dest):
    if refresh:
      if not cfg.refreshRemoteTags(dest, url, nonInteractive) and not nonInteractive:
        cfg.logWarn("Failed to refresh " & dest)
    return true
  if cfg.cloneRepo(url, dest, nonInteractive):
    return true
  withLock failedClonesLock:
    failedClones.incl(dest)
  if not nonInteractive:
    cfg.logWarn("Failed to clone " & url)
  false

proc checkoutTag*(cfg: DatpkgrConfig, dest, tag: string): bool =
  let (output, code) = cfg.gitExec("git -C " & dest & " checkout " & tag & " --quiet")
  code == 0

proc checkoutHead*(cfg: DatpkgrConfig, dest: string, refresh = false): bool =
  if refresh:
    discard cfg.gitExec("git -C " & dest & " fetch origin --quiet", env = gitEnv())
  let (defOut, _) = cfg.gitExec("git -C " & dest &
    " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var branch = defOut.strip()
  if branch.startsWith("refs/remotes/origin/"):
    branch = branch["refs/remotes/origin/".len .. ^1]
  if branch.len == 0:
    branch = "master"
  let (output, code) = cfg.gitExec("git -C " & dest &
    " checkout -q origin/" & branch & " --")
  if code == 0:
    return true
  for b in ["master", "main"]:
    let (out2, code2) = cfg.gitExec("git -C " & dest &
      " checkout -q origin/" & b & " --")
    if code2 == 0:
      return true
  false

proc checkoutRef*(cfg: DatpkgrConfig, dest, refStr: string, refresh = false): bool =
  if refStr.len > 0 and refStr.toLowerAscii == "head":
    return cfg.checkoutHead(dest, refresh)
  discard cfg.gitExec("git -C " & dest & " fetch origin " & refStr & " --quiet",
    env = gitEnv())
  let (output, code) = cfg.gitExec("git -C " & dest & " checkout " & refStr & " --quiet")
  if code != 0:
    cfg.logWarn("Branch or ref '" & refStr & "' not found. Check the spelling.")
  code == 0

proc checkoutTagRaw*(dest, tag: string): bool {.gcsafe.} =
  let (output, code) = gitExecRaw("git -C " & dest & " checkout " & tag & " --quiet")
  code == 0

proc checkoutHeadRaw*(dest: string, refresh = false): bool {.gcsafe.} =
  if refresh:
    discard gitExecRaw("git -C " & dest & " fetch origin --quiet", env = gitEnv())
  let (defOut, _) = gitExecRaw("git -C " & dest & " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var branch = defOut.strip()
  if branch.startsWith("refs/remotes/origin/"):
    branch = branch["refs/remotes/origin/".len .. ^1]
  if branch.len == 0:
    branch = "master"
  let (output, code) = gitExecRaw("git -C " & dest & " checkout -q origin/" & branch & " --")
  if code == 0:
    return true
  for b in ["master", "main"]:
    let (out2, code2) = gitExecRaw("git -C " & dest & " checkout -q origin/" & b & " --")
    if code2 == 0:
      return true
  false

proc checkoutRefRaw*(dest, refStr: string, refresh = false): bool {.gcsafe.} =
  if refStr.len > 0 and refStr.toLowerAscii == "head":
    return checkoutHeadRaw(dest, refresh)
  discard gitExecRaw("git -C " & dest & " fetch origin " & refStr & " --quiet", env = gitEnv())
  let (output, code) = gitExecRaw("git -C " & dest & " checkout " & refStr & " --quiet")
  code == 0

type
  GitHeadInfo* = object
    hash*: string
    date*: string
    author*: string
    subject*: string

proc gitHeadInfo*(cfg: DatpkgrConfig, name, url: string): Option[GitHeadInfo] =
  var repo = cfg.pkgsCachePath() / name
  var own = false
  if not dirExists(repo):
    repo = getTempDir() / ("datpkg_head_" & $getMonoTime().ticks)
    if not cfg.clonePackage(url, repo, nonInteractive = true):
      return none(GitHeadInfo)
    own = true
  else:
    discard cfg.checkoutHead(repo)
  let (output, code) = cfg.gitExec("git -C " & repo &
    " log -1 --format=%H%n%aI%n%an%n%s")
  if own:
    removeDir(repo)
  if code != 0 or output.len == 0:
    return none(GitHeadInfo)
  let lines = output.splitLines()
  if lines.len < 3:
    return none(GitHeadInfo)
  some(GitHeadInfo(
    hash: lines[0],
    date: lines[1],
    author: lines[2],
    subject: lines[3]))
