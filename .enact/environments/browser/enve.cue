package enve

import (
	"list"
	"n8n.io:enve"
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

profiles: dev: schema.#Profile & enve.#Runtime & {
	name: "n8n-browser"
	tools: list.Concat([enve.#RuntimeTools, [
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell", "ffmpeg"]},
	]])
}
