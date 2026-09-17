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

var sshFailedHosts* = initHashSet[string]()
var sshFailedHostsLock*: Lock
sshFailedHostsLock.initLock()

proc sshHostOf*(url: string): string =
  ## Host part of an http(s) URL, or "" when the URL isn't ssh-convertible
  ## (already ssh-style, or unparsable — no separate SSH attempt exists then).
  var u = url.strip()
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if not (u.startsWith("https://") or u.startsWith("http://")):
    return ""
  let rest = u.split("://")[1]
  let slashPos = rest.find('/')
  if slashPos < 0:
    return ""
  rest[0 ..< slashPos]

proc sshKnownBad*(host: string): bool =
  ## True when SSH to `host` already failed once in this process — later
  ## clones then skip the doomed SSH attempt (up to `ConnectTimeout` stall).
  if host.len == 0:
    return false
  {.cast(gcsafe).}:
    withLock sshFailedHostsLock:
      result = host in sshFailedHosts

proc markSshBad*(host: string) =
  if host.len == 0:
    return
  {.cast(gcsafe).}:
    withLock sshFailedHostsLock:
      sshFailedHosts.incl(host)

proc emitCloneStart(cfg: DatpkgrConfig, url, dest: string) =
  ## Main-thread only: the cfg-level git procs below never run on workers
  ## (workers use the `*Raw` variants), so invoking the host callback here
  ## is single-threaded by construction.
  if cfg.callbacks.onCloneStart != nil:
    cfg.callbacks.onCloneStart(dest.extractFilename, url)
    try: flushFile(stdout) except: discard

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

proc updateSubmodules*(cfg: DatpkgrConfig, dest: string): bool {.gcsafe.} =
  ## Init/update submodules in `dest`. Only runs when `cfg.allowSubmodules`
  ## is enabled; otherwise a no-op returning true. Warn-and-continue on
  ## failure so a dead/private submodule never aborts the install.
  if not cfg.allowSubmodules:
    return true
  if not fileExists(dest / ".gitmodules"):
    return true
  let (_, code) = cfg.gitExec("git -C " & quoteShell(dest) &
    " -c protocol.file.allow=always submodule update --init --recursive --quiet")
  if code != 0:
    cfg.logWarn("Failed to init submodules in " & dest & " - continuing with partial content")
  true

proc updateSubmodulesRaw*(dest: string, allowSubmodules = false): bool {.gcsafe.} =
  ## Thread-safe submodule init without touching `cfg` (usable off main thread).
  if not allowSubmodules:
    return true
  if not fileExists(dest / ".gitmodules"):
    return true
  let (_, code) = gitExecRaw("git -C " & quoteShell(dest) &
    " -c protocol.file.allow=always submodule update --init --recursive --quiet")
  code == 0

proc cloneRepo*(cfg: DatpkgrConfig, url, dest: string, nonInteractive = false): bool =
  cfg.emitCloneStart(url, dest)
  let env = gitEnv(nonInteractive)
  let subFlag = if cfg.allowSubmodules: " --recurse-submodules" else: ""
  let sshUrl = toGitSshUrl(url)
  if sshUrl != url and not sshKnownBad(sshHostOf(url)):
    let (o1, c1) = cfg.gitExec("git -c protocol.file.allow=always clone" & subFlag & " " & sshUrl & " " & quoteShell(dest), env = env)
    if c1 == 0:
      discard cfg.gitExec("git -C " & quoteShell(dest) & " fetch --tags --quiet", env = env)
      discard cfg.updateSubmodules(dest)
      return true
    # SSH failed (blocked network or auth) — remember the host so later
    # clones skip the doomed SSH attempt and go straight to the plain URL.
    markSshBad(sshHostOf(url))
  let (o2, c2) = cfg.gitExec("git -c protocol.file.allow=always clone" & subFlag & " " & url & " " & quoteShell(dest), env = env)
  if c2 == 0:
    discard cfg.gitExec("git -C " & quoteShell(dest) & " fetch --tags --quiet", env = env)
    discard cfg.updateSubmodules(dest)
    return true
  false

proc refreshRemoteTags*(cfg: DatpkgrConfig, dest, url: string, nonInteractive = false): bool =
  cfg.emitCloneStart(url, dest)
  let env = gitEnv(nonInteractive)
  let sshUrl = toGitSshUrl(url)
  if sshUrl != url and not sshKnownBad(sshHostOf(url)):
    discard cfg.gitExec("git -C " & quoteShell(dest) & " remote set-url origin " & sshUrl)
    let (output, exitCode) = cfg.gitExec("git -C " & quoteShell(dest) &
      " fetch --tags --prune --quiet", env = env)
    if exitCode == 0:
      discard cfg.updateSubmodules(dest)
      return true
    markSshBad(sshHostOf(url))
  discard cfg.gitExec("git -C " & quoteShell(dest) & " remote set-url origin " & url)
  let (out2, code2) = cfg.gitExec("git -C " & quoteShell(dest) &
    " fetch --tags --prune --quiet", env = env)
  if code2 != 0:
    return false
  discard cfg.updateSubmodules(dest)
  true

proc cloneRepoRaw*(url, dest: string, nonInteractive = false,
    allowSubmodules = false): bool {.gcsafe.} =
  ## Worker-safe clone: no `cfg`, no callbacks, no stores. Progress (if any)
  ## is emitted by the calling worker through its progress channel.
  let env = gitEnv(nonInteractive)
  let subFlag = if allowSubmodules: " --recurse-submodules" else: ""
  let sshUrl = toGitSshUrl(url)
  if sshUrl != url and not sshKnownBad(sshHostOf(url)):
    let (_, c1) = gitExecRaw("git -c protocol.file.allow=always clone" & subFlag & " " & sshUrl & " " & quoteShell(dest), env = env)
    if c1 == 0:
      discard gitExecRaw("git -C " & quoteShell(dest) & " fetch --tags --quiet", env = env)
      discard updateSubmodulesRaw(dest, allowSubmodules)
      return true
    markSshBad(sshHostOf(url))
  let (_, c2) = gitExecRaw("git -c protocol.file.allow=always clone" & subFlag & " " & url & " " & quoteShell(dest), env = env)
  if c2 == 0:
    discard gitExecRaw("git -C " & quoteShell(dest) & " fetch --tags --quiet", env = env)
    discard updateSubmodulesRaw(dest, allowSubmodules)
    return true
  false

proc refreshRemoteTagsRaw*(dest, url: string, nonInteractive = false,
    allowSubmodules = false): bool {.gcsafe.} =
  ## Worker-safe fetch: no `cfg`, no callbacks, no stores.
  let env = gitEnv(nonInteractive)
  let sshUrl = toGitSshUrl(url)
  if sshUrl != url and not sshKnownBad(sshHostOf(url)):
    discard gitExecRaw("git -C " & quoteShell(dest) & " remote set-url origin " & sshUrl)
    let (_, exitCode) = gitExecRaw("git -C " & quoteShell(dest) &
      " fetch --tags --prune --quiet", env = env)
    if exitCode == 0:
      discard updateSubmodulesRaw(dest, allowSubmodules)
      return true
    markSshBad(sshHostOf(url))
  discard gitExecRaw("git -C " & quoteShell(dest) & " remote set-url origin " & url)
  let (_, code2) = gitExecRaw("git -C " & quoteShell(dest) &
    " fetch --tags --prune --quiet", env = env)
  if code2 != 0:
    return false
  discard updateSubmodulesRaw(dest, allowSubmodules)
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
  let (output, code) = cfg.gitExec("git -C " & quoteShell(dest) & " checkout " & quoteShell(tag) & " --quiet")
  if code != 0:
    return false
  discard cfg.updateSubmodules(dest)
  true

proc checkoutHead*(cfg: DatpkgrConfig, dest: string, refresh = false): bool =
  if refresh:
    discard cfg.gitExec("git -C " & quoteShell(dest) & " fetch origin --quiet", env = gitEnv())
  let (defOut, _) = cfg.gitExec("git -C " & quoteShell(dest) &
    " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var branch = defOut.strip()
  if branch.startsWith("refs/remotes/origin/"):
    branch = branch["refs/remotes/origin/".len .. ^1]
  if branch.len == 0:
    branch = "master"
  let (output, code) = cfg.gitExec("git -C " & quoteShell(dest) &
    " checkout -q origin/" & branch & " --")
  if code == 0:
    discard cfg.updateSubmodules(dest)
    return true
  for b in ["master", "main"]:
    let (out2, code2) = cfg.gitExec("git -C " & quoteShell(dest) &
      " checkout -q origin/" & b & " --")
    if code2 == 0:
      discard cfg.updateSubmodules(dest)
      return true
  false

proc checkoutRef*(cfg: DatpkgrConfig, dest, refStr: string, refresh = false): bool =
  if refStr.len > 0 and refStr.toLowerAscii == "head":
    return cfg.checkoutHead(dest, refresh)
  discard cfg.gitExec("git -C " & quoteShell(dest) & " fetch origin " & quoteShell(refStr) & " --quiet",
    env = gitEnv())
  let (output, code) = cfg.gitExec("git -C " & quoteShell(dest) & " checkout " & quoteShell(refStr) & " --quiet")
  if code != 0:
    cfg.logWarn("Branch or ref '" & refStr & "' not found. Check the spelling.")
    return false
  discard cfg.updateSubmodules(dest)
  true

proc checkoutTagRaw*(dest, tag: string, allowSubmodules = false): bool {.gcsafe.} =
  let (output, code) = gitExecRaw("git -C " & quoteShell(dest) & " checkout " & quoteShell(tag) & " --quiet")
  if code != 0:
    return false
  discard updateSubmodulesRaw(dest, allowSubmodules)
  true

proc checkoutHeadRaw*(dest: string, refresh = false, allowSubmodules = false): bool {.gcsafe.} =
  if refresh:
    discard gitExecRaw("git -C " & quoteShell(dest) & " fetch origin --quiet", env = gitEnv())
  let (defOut, _) = gitExecRaw("git -C " & quoteShell(dest) & " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var branch = defOut.strip()
  if branch.startsWith("refs/remotes/origin/"):
    branch = branch["refs/remotes/origin/".len .. ^1]
  if branch.len == 0:
    branch = "master"
  let (output, code) = gitExecRaw("git -C " & quoteShell(dest) & " checkout -q origin/" & branch & " --")
  if code == 0:
    discard updateSubmodulesRaw(dest, allowSubmodules)
    return true
  for b in ["master", "main"]:
    let (out2, code2) = gitExecRaw("git -C " & quoteShell(dest) & " checkout -q origin/" & b & " --")
    if code2 == 0:
      discard updateSubmodulesRaw(dest, allowSubmodules)
      return true
  false

proc checkoutRefRaw*(dest, refStr: string, refresh = false, allowSubmodules = false): bool {.gcsafe.} =
  if refStr.len > 0 and refStr.toLowerAscii == "head":
    return checkoutHeadRaw(dest, refresh, allowSubmodules)
  discard gitExecRaw("git -C " & quoteShell(dest) & " fetch origin " & quoteShell(refStr) & " --quiet", env = gitEnv())
  let (output, code) = gitExecRaw("git -C " & quoteShell(dest) & " checkout " & quoteShell(refStr) & " --quiet")
  if code != 0:
    return false
  discard updateSubmodulesRaw(dest, allowSubmodules)
  true

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
