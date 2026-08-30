import std/[os, unittest, json, strutils]
import datpkgr/config
import helpers

suite "config — path helpers":
  test "dbPath etc are under rootPath":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.dbPath() == cfg.rootPath / (cfg.appName & ".db")
    check cfg.versionsDBPath() == cfg.rootPath / "versions.db"
    check cfg.pkgsPath() == cfg.rootPath / "packages"
    check cfg.pkgsCachePath() == cfg.rootPath / "packages" / "_cache"
    check cfg.sourcesPath() == "sources.json"
    check cfg.registriesDir() == "registries"

  test "manifestNameForPkg fallback":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.manifestNameForPkg("foo") == "manifest.json"

  test "custom manifestFileName":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.manifestFileName = proc(pkg: string): string = pkg & ".nimble"
    check cfg.manifestNameForPkg("spry") == "spry.nimble"

suite "config — isInsidePkgs / isInsideDevelop":
  test "the registry root itself is inside":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.isInsidePkgs(cfg.pkgsPath())

  test "a child of the registry is inside":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.isInsidePkgs(cfg.pkgsPath() / "spry" / "1.2.0")

  test "a sibling with a name prefix is outside":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check not cfg.isInsidePkgs(cfg.pkgsPath() & "X")
    check not cfg.isInsidePkgs(cfg.pkgsPath() & "_cache")

  test "the parent directory is outside":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check not cfg.isInsidePkgs(cfg.pkgsPath().parentDir())

  test "develop path checks":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    check cfg.isInsideDevelop(cfg.developPath() / "foo")
    check not cfg.isInsideDevelop(cfg.pkgsPath() / "foo")
    check not cfg.isInsideDevelop(getTempDir())

suite "config — safeRemove guards":
  test "leaves an outside temp dir untouched":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    let dir = getTempDir() / "datpkgr_outside" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    cfg.safeRemoveDir(dir)
    check dirExists(dir)

  test "removes inside pkgs":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    let inside = cfg.pkgsPath() / "todelete" / "1.0.0"
    createDir(inside)
    check dirExists(inside)
    cfg.safeRemoveDir(inside)
    check not dirExists(inside)

  test "safeRemoveSymlink refuses outside develop":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    let target = getTempDir() / "datpkgr_symtarget" / $getCurrentProcessId()
    let link = getTempDir() / "datpkgr_symlink" / $getCurrentProcessId()
    createDir(target)
    createDir(link.parentDir())
    defer:
      removeDir(target)
      if symlinkExists(link):
        try: removeFile(link)
        except OSError:
          try: removeDir(link) except OSError: discard
    createSymlink(target, link)
    cfg.safeRemoveSymlink(link)
    check symlinkExists(link)

  test "safeRemoveSymlink removes inside develop":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    discard existsOrCreateDir(cfg.developPath())
    let target = getTempDir() / "datpkgr_develop_target" / $getCurrentProcessId()
    createDir(target)
    defer:
      if symlinkExists(cfg.developPath() / "mydev"):
        try: removeFile(cfg.developPath() / "mydev")
        except OSError:
          try: removeDir(cfg.developPath() / "mydev") except OSError: discard
      removeDir(target)
    let link = cfg.developPath() / "mydev"
    createSymlink(target, link)
    check symlinkExists(link)
    cfg.safeRemoveSymlink(link)
    check not symlinkExists(link)

suite "config — manifest finders":
  test "findManifestInDir finds file in dir, skips toolchain":
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.manifestFileName = proc(pkg: string): string =
      if pkg == "*": return "*.nimble"
      pkg & ".nimble"
    cfg.toolchainName = "nim"
    cfg.manifestFinder = proc(dir: string): string =
      for f in walkFiles(dir / "*.nimble"):
        if f.extractFilename != "nim.nimble": return f
      ""
    let dir = getTempDir() / "datpkgr_manifest" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "spry.nimble", "version=\"1.0.0\"")
    writeFile(dir / "nim.nimble", "version=\"2.0.0\"")
    let found = cfg.findManifestInDir(dir)
    check found.extractFilename == "spry.nimble"

  test "callbacks are invoked":
    var captured {.global.}: seq[string]
    captured = @[]
    let cfg = tempCfg()
    defer: cleanupCfg(cfg)
    cfg.callbacks.log = proc(lvl: LogLevel, msg: string) {.gcsafe.} =
      try:
        {.cast(gcsafe).}:
          captured.add($lvl & ":" & msg)
      except: discard
    cfg.debugEnabled = true
    cfg.logDebug("hello")
    var found = false
    {.cast(gcsafe).}:
      for m in captured:
        if "hello" in m: found = true
    check found
