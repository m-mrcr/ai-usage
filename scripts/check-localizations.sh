#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
EN_STRINGS="$ROOT_DIR/Shared/en.lproj/Localizable.strings"
JA_STRINGS="$ROOT_DIR/Shared/ja.lproj/Localizable.strings"

plutil -lint "$EN_STRINGS" "$JA_STRINGS" >/dev/null

ruby -rjson -ropen3 -e '
  # Both the catalog and the Swift sources contain Japanese. In a shell with LANG unset,
  # it defaults to US-ASCII and JSON.parse/scan would fail, so this check pins UTF-8 for itself only.
  Encoding.default_external = Encoding::UTF_8
  Encoding.default_internal = Encoding::UTF_8

  def load_strings(path)
    output, status = Open3.capture2("plutil", "-convert", "json", "-o", "-", path)
    abort "Could not parse #{path}" unless status.success?
    JSON.parse(output)
  end

  english = load_strings(ARGV.fetch(0))
  japanese = load_strings(ARGV.fetch(1))
  missing_ja = english.keys - japanese.keys
  missing_en = japanese.keys - english.keys
  unless missing_ja.empty? && missing_en.empty?
    warn "Missing from Japanese: #{missing_ja.sort.join(", ")}" unless missing_ja.empty?
    warn "Missing from English: #{missing_en.sort.join(", ")}" unless missing_en.empty?
    exit 1
  end

  source_keys = Dir[File.join(ARGV.fetch(2), "{App,Widget,Shared}", "**", "*.swift")]
    .flat_map { |path| File.read(path).scan(/L10n\.(?:text|format)\(\s*"([^"]+)"/m).flatten }
    .uniq
  missing_catalog = source_keys - english.keys
  unless missing_catalog.empty?
    warn "Missing localization keys: #{missing_catalog.sort.join(", ")}"
    exit 1
  end
' "$EN_STRINGS" "$JA_STRINGS" "$ROOT_DIR"
