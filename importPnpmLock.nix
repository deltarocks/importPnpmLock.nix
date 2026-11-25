# SPDX-FileCopyrightText: 2026 Sefa Eyeoglu <contact@scrumplex.net>
#
# SPDX-License-Identifier: MIT

{
  lib,
  runCommand,
  yq-go,
  mitm-cache,
  config,
}:
{
  pname,
  version,
  lockFile,
  manualEntries ? { },
  useBuiltinFetchurl ? false,
}:
let
  supportedLockFileVersions = [
    "9.0"
  ];

  fromYAML = builtins.wasm {
    path = ./wasm/nix_wasm_plugin_yaml.wasm;
    function = "fromYAML";
  };

  importYAMLDocuments =
    file:
    if builtins ? wasm then
      fromYAML (builtins.readFile file)
    else
      let
        json =
          runCommand "${pname}-pnpm-lock.json"
            {
              nativeBuildInputs = [ yq-go ];
            }
            ''
              yq --output-format json eval-all '[.]' ${file} > $out
            '';
      in
      lib.importJSON json;

  splitName = builtins.match "^(@?[^@]+)@(.+)$";

  urlFromName =
    name:
    let
      c = splitName name;
      scopedName = builtins.head c;
      version = lib.last c;
      versionIsUrl = lib.hasPrefix "http" version;
      packageName = lib.last (lib.splitString "/" scopedName);
    in
    if versionIsUrl then
      version
    else
      "https://registry.npmjs.org/${scopedName}/-/${packageName}-${version}.tgz";

  applyMirrorToUrl =
    url:
    let
      mUrl = builtins.match "(.+)://([^/]+)/(.+)" url;
      scheme = builtins.elemAt mUrl 0;
      host = builtins.elemAt mUrl 1;
      path = builtins.elemAt mUrl 2;
    in
    if config.npmRegistryOverrides ? "${host}" then
      "${scheme}://${config.npmRegistryOverrides."${host}"}/${path}"
    else
      url;

  documents = importYAMLDocuments lockFile;

  data = lib.last documents;

  mapPackageToMitmCacheEntry =
    name: package:
    let
      resolution = package.resolution or { };
      url = resolution.tarball or (applyMirrorToUrl (urlFromName name));
      integrity = resolution.integrity or manualEntries.${name} or null;
    in
    assert lib.assertMsg (integrity != null) ''
      Package ${name} doesn't have an integrity entry.

      To fix this, add a manual entry using

        importPnpmLock {
          lockFile = ${lockFile};
          manualEntries = {
            "${name}" = "";
          };
        }
    '';
    lib.nameValuePair url {
      hash = integrity;
    };

  # directory resolution does not need any fetching
  filterPackageEntry = _: package: (package.resolution or { }).type or null != "directory";

  lockFileVersion = data.lockfileVersion or null;

  fetch =
    if useBuiltinFetchurl then
      mitm-cache.fetch.override {
        fetchurl = { url, hash }: import <nix/fetchurl.nix> { inherit url hash; };
      }
    else
      mitm-cache.fetch;
in
assert lib.assertMsg (lockFileVersion != null) ''
  lockFile ${lockFile} does not look like a supported lock file.
  Unable to read lock file version.
'';
assert lib.assertMsg (builtins.elem lockFileVersion supportedLockFileVersions) ''
  File ${lockFile} is not a supported lock file.

  Supported versions are ${lib.concatStrings supportedLockFileVersions}

  Found version ${lockFileVersion}
'';
assert lib.assertMsg (data ? packages) ''
  File ${lockFile} does not contain a list of locked packages.
  Is it a valid lock file?
'';
fetch {
  name = "${pname}-pnpm-mitm-cache-${version}";
  data = lib.mapAttrs' mapPackageToMitmCacheEntry (lib.filterAttrs filterPackageEntry data.packages);
}
