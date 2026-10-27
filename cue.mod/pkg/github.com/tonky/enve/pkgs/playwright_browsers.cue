package pkgs

import (
	"strings"
	"github.com/tonky/enve/schema/v1:schema"
)

// Playwright's own browser builds for one Playwright version, as one store object laid out
// the way `playwright install` lays out its cache, exported as PLAYWRIGHT_BROWSERS_PATH:
//
//	tools: [pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell", "ffmpeg"]}]
//
// `version` is the project's Playwright version (its lockfile's playwright-core): Playwright
// looks a browser up by the revision its own browsers.json names, so the two must match.
// `features` names the browsers (Playwright's names). Each archive is a fixed-output fetch
// checked against the sha256 recorded in pkgs/playwright.cue. On Linux the builds expect a
// distribution's shared libraries: auto-patchelf points their interpreter and RPATH at the
// snapshot's libraries instead, so nothing comes from the host. Which libraries is read from the
// archives themselves (`linuxNeeds`, recorded with the hashes). Playwright's host-library check
// is skipped: the build already proved every library resolves. Pages render with the fonts the
// object carries: FONTCONFIG_FILE names its own fontconfig file (_playwrightFonts).
#PlaywrightBrowsers: schema.#PackageSpec & {
	// A version pkgs/playwright.cue records; indexing the table with any other fails.
	version: string
	features: [...string]
	pname: "playwright-browsers"

	let builds = _playwrightBuilds[version]
	fetch: {
		for browser in features {
			(_playwrightVar[browser]): {
				url: {for system, archive in builds[browser].archives {(system): archive.url}}
				sha256: {for system, archive in builds[browser].archives {(system): archive.sha256}}
			}
		}
	}
	// The packages providing what the browsers' Linux builds link (their recorded `linuxNeeds`),
	// as a set so browsers sharing a library list it once. A soname _playwrightLibraries doesn't
	// map fails evaluation here, before any download.
	let linux = {
		for name in _playwrightLinuxTools {(name): true}
		for browser in features for soname in builds[browser].linuxNeeds {(_playwrightLibraries[soname]): true}
	}
	buildInputs: [
		{pname: "unzip"},
		for name, _ in linux {pname: name, platforms: [schema.#Platform.Linux]},
	]
	let unpack = strings.Join([
		for browser in features {"unzip -q \"$\(_playwrightVar[browser])\" -d \"$out/\(builds[browser].dir)\"\ntouch \"$out/\(builds[browser].dir)/INSTALLATION_COMPLETE\""},
	], "\n")
	installPhase: """
		set -eu
		\(unpack)
		\(_playwrightPatch)
		\(_playwrightFonts)
		"""
	exports: {
		PLAYWRIGHT_BROWSERS_PATH:                   "$out"
		PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS: "1"
		FONTCONFIG_FILE:                            "$out/fonts.conf"
	}
}

_playwrightVar: {
	"chromium":                "playwright_chromium"
	"chromium-headless-shell": "playwright_chromium_headless_shell"
	"firefox":                 "playwright_firefox"
	"webkit":                  "playwright_webkit"
	"ffmpeg":                  "playwright_ffmpeg"
}

// Build tools, and the fonts the Linux browsers render with (_playwrightFonts).
_playwrightLinuxTools: ["auto-patchelf", "patchelf", "dejavu_fonts", "liberation_ttf"]

// The nixpkgs package providing each library a recorded Linux build links (its `linuxNeeds`:
// the DT_NEEDED sonames no file of its own archive provides).
_playwrightLibraries: {
	for soname in ["libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libresolv.so.2", "ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2"] {(soname): "glibc"}
	"libgcc_s.so.1":          "gcc-unwrapped"
	"libstdc++.so.6":         "gcc-unwrapped"
	"libasound.so.2":         "alsa-lib"
	"libatk-1.0.so.0":        "at-spi2-core"
	"libatk-bridge-2.0.so.0": "at-spi2-core"
	"libatspi.so.0":          "at-spi2-core"
	"libcairo.so.2":          "cairo"
	"libcairo-gobject.so.2":  "cairo"
	"libcups.so.2":           "cups"
	"libdbus-1.so.3":         "dbus"
	"libexpat.so.1":          "expat"
	"libfontconfig.so.1":     "fontconfig"
	"libfreetype.so.6":       "freetype"
	"libgbm.so.1":            "libgbm"
	"libgdk-3.so.0":          "gtk3"
	"libgtk-3.so.0":          "gtk3"
	"libgdk_pixbuf-2.0.so.0": "gdk-pixbuf"
	"libgio-2.0.so.0":        "glib"
	"libglib-2.0.so.0":       "glib"
	"libgobject-2.0.so.0":    "glib"
	"libnspr4.so":            "nspr"
	"libnss3.so":             "nss"
	"libnssutil3.so":         "nss"
	"libsmime3.so":           "nss"
	"libpango-1.0.so.0":      "pango"
	"libpangocairo-1.0.so.0": "pango"
	"libudev.so.1":           "udev"
	"libX11.so.6":            "libx11"
	"libX11-xcb.so.1":        "libx11"
	"libxcb.so.1":            "libxcb"
	"libxcb-shm.so.0":        "libxcb"
	"libXcomposite.so.1":     "libxcomposite"
	"libXcursor.so.1":        "libxcursor"
	"libXdamage.so.1":        "libxdamage"
	"libXext.so.6":           "libxext"
	"libXfixes.so.3":         "libxfixes"
	"libXi.so.6":             "libxi"
	"libxkbcommon.so.0":      "libxkbcommon"
	"libXrandr.so.2":         "libxrandr"
	"libXrender.so.1":        "libxrender"
}

// Linux: every ELF in the output gets the snapshot's interpreter and an RPATH over the build
// inputs' library directories; a library no input provides fails the build here. Each browser
// is patched on its own, so one never resolves a library to another's bundled copy (Firefox
// ships its own NSS; Chromium links nixpkgs'). auto-patchelf writes the absolute directory it
// found each library in, so two spellings are put right after it: a directory of the output
// itself (the build's staging dir, gone once the object is published) becomes $ORIGIN-relative,
// and where /nix/store is a link to enve's store, that machine's store root goes back to
// /nix/store, so the object is the same on every machine.
_playwrightPatch: """
	if [ "$(uname -s)" = Linux ]; then
		for browser in "$out"/*/; do
			auto-patchelf --paths "$browser" --libs $(printf '%s' "$LIBRARY_PATH" | tr ':' ' ')
		done
		root=$(cd /nix/store && pwd -P)
		outreal=$(cd "$out" && pwd -P)
		# The path from directory $1 to directory $2, both inside $out.
		relative() {
			local from=$1 up=
			while [ "${2#"$from"/}" = "$2" ] && [ "$2" != "$from" ]; do from=${from%/*}; up="$up../"; done
			local rest=${2#"$from"}
			rest="$up${rest#/}"
			printf '%s' "${rest%/}"
		}
		shopt -s globstar
		for elf in "$out"/**; do
			[ -f "$elf" ] && [ ! -L "$elf" ] || continue
			interp=$(patchelf --print-interpreter "$elf" 2>/dev/null) || interp=
			case "$interp" in "$root"/*) patchelf --set-interpreter "/nix/store/${interp#"$root"/}" "$elf" ;; esac
			rpath=$(patchelf --print-rpath "$elf" 2>/dev/null) || continue
			fixed=
			for entry in ${rpath//:/ }; do
				case "$entry" in "$outreal" | "$outreal"/*) entry="$out${entry#"$outreal"}" ;; esac
				case "$entry" in
				"$out" | "$out"/*)
					rel=$(relative "${elf%/*}" "$entry")
					entry='$ORIGIN'${rel:+/$rel}
					;;
				"$root"/*) entry="/nix/store/${entry#"$root"/}" ;;
				esac
				fixed=${fixed:+$fixed:}$entry
			done
			[ "$fixed" = "$rpath" ] || patchelf --set-rpath "$fixed" "$elf"
		done
	fi
	"""

// The fontconfig file FONTCONFIG_FILE names. On Linux it lists only the fonts this object's
// inputs carry (DejaVu, and Liberation, metric-compatible with Arial, Times New Roman and
// Courier New), so a page renders the same on every machine whatever fonts the host has; the
// generic families resolve to them. darwin's browsers don't read fontconfig: there the file
// lists the system's font dirs, what fontconfig reads by default, for other tools in the
// profile. The cache goes to $XDG_CACHE_HOME/fontconfig.
_playwrightFonts: """
	fontdirs() {
		root=$(cd /nix/store 2>/dev/null && pwd -P) || root=/nix/store
		for dir in $(printf '%s' "${XDG_DATA_DIRS:-}" | tr ':' ' '); do
			[ -d "$dir/fonts" ] || continue
			case "$dir" in "$root"/*) dir="/nix/store/${dir#"$root"/}" ;; esac
			printf '  <dir>%s/fonts</dir>
	' "$dir"
		done
		if [ "$(uname -s)" = Darwin ]; then
			printf '  <dir>%s</dir>
	' /System/Library/Fonts /Library/Fonts
			printf '  <dir>~/Library/Fonts</dir>
	'
		fi
	}
	prefer() {
		printf '  <alias binding="same"><family>%s</family><prefer><family>%s</family><family>%s</family></prefer></alias>
	' "$@"
	}
	{
		printf '<?xml version="1.0"?>
	<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
	<fontconfig>
	'
		fontdirs
		printf '  <cachedir prefix="xdg">fontconfig</cachedir>
	'
		prefer sans-serif "Liberation Sans" "DejaVu Sans"
		prefer serif "Liberation Serif" "DejaVu Serif"
		prefer monospace "Liberation Mono" "DejaVu Sans Mono"
		prefer Arial "Liberation Sans" "DejaVu Sans"
		prefer Helvetica "Liberation Sans" "DejaVu Sans"
		prefer "Times New Roman" "Liberation Serif" "DejaVu Serif"
		prefer "Courier New" "Liberation Mono" "DejaVu Sans Mono"
		printf '</fontconfig>
	'
	} > "$out/fonts.conf"
	"""
