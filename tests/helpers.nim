import std/[os, strutils, tempfiles, json]
when defined(windows):
  import std/osproc
import datpkgr/config
import datpkgr/types

when defined(windows):
  proc makeDirLink*(target, link: string) =
    ## Fixture dir link without privilege: real symlink when allowed,
    ## otherwise an NTFS junction (`mklink /J` needs none). Both report
    ## `symlinkExists` (any reparse point).
    try:
      createSymlink(target, link)
      return
    except OSError:
      discard
    let (_, code) = execCmdEx("cmd /c mklink /J " & quoteShell(link) &
      " " & quoteShell(target))
    doAssert code == 0, "could not create fixture link: " & link

  proc removeDirLink*(link: string) =
    ## Unlink a fixture dir link (symlink or junction) without touching its
    ## target — `removeDir` would recurse through junctions.
    if symlinkExists(link) and dirExists(link):
      let (_, code) = execCmdEx("cmd /c rmdir " & quoteShell(link))
      if code == 0:
        return
    try:
      removeFile(link)
    except OSError:
      try: removeDir(link) except OSError: discard
else:
  proc makeDirLink*(target, link: string) =
    createSymlink(target, link)

  proc removeDirLink*(link: string) =
    if symlinkExists(link):
      try:
        removeFile(link)
      except OSError:
        try: removeDir(link) except OSError: discard

proc tempCfg*(app = "datpkgr_test"): DatpkgrConfig =
  let dir = createTempDir("datpkgr_", "")
  result = newDatpkgrConfig(app, dir)
  # reduce noise: silence log by default
  result.callbacks.log = proc(lvl: LogLevel, msg: string) {.gcsafe.} = discard

proc cleanupCfg*(cfg: DatpkgrConfig) =
  if cfg != nil and cfg.rootPath.len > 0 and dirExists(cfg.rootPath):
    try: removeDir(cfg.rootPath)
    except: discard

proc withTempCfg*(body: proc(cfg: DatpkgrConfig)) =
  let cfg = tempCfg()
  defer: cleanupCfg(cfg)
  body(cfg)

proc fakeParser*(content: string, path: string): Manifest =
  ## Minimal Manifest parser for tests: name = filename without ext, version from `version = "..."` line
  var m = Manifest(path: path, name: path.extractFilename.changeFileExt(""), extra: newJObject())
  for line in content.splitLines():
    let t = line.strip()
    if t.startsWith("version"):
      let eq = t.find('=')
      if eq >= 0:
        var v = t[eq+1..^1].strip().strip(chars={'"', '\''})
        m.version = v
  # keep dependencies empty, extra holds skip/src etc if needed
  m
