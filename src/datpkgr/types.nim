# datpkgr - An app/language agnostic package manager kit
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr

import std/[tables, json, os, sequtils, strutils]
import ./resolver

export resolver

type
  Source* = object
    name*: string
    url*: string

  Package* = object
    name*: string
    url*: string
    `method`*: string
    tags*: seq[string]
    description*: string
    license*: string
    web*: string

  PkgRef* = object
    name*: string
    refStr*: string
    url*: string

  PkgDependency* = object
    name*: string
    url*: string
    constraint*: VersionConstraint
    branch*: string
    tag*: string
    features*: seq[string]
    isToolchain*: bool

  Manifest* = object
    path*: string
    name*: string
    version*: string
    description*: string
    license*: string
    dependencies*: seq[PkgDependency]
    features*: Table[string, seq[PkgDependency]]
    devDependencies*: seq[PkgDependency]
    extra*: JsonNode

  DepEntry* = tuple[name: string, version: string]

  ManifestParser* = proc(content: string, path: string): Manifest
  ManifestFinder* = proc(dir: string): string
