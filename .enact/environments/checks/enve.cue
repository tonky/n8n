package enve

import (
	"n8n.io:enve"
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// The installer and static jobs share exact Node, pnpm and Python identities.
// Services remain declared for port expansion, but their packages are inactive.
profiles: dev: schema.#Profile & enve.#Runtime & {
	name: "n8n-checks"
	tools: [
		enve.#Pnpm,
		pkgs.nodejs & {version: "24"},
		pkgs.python & {version: "3.13"},
		pkgs.uv,
		{pname: "curl"},
		{pname: "ripgrep"},
		{pname: "bash"},
		{pname: "coreutils"},
		{pname: "flock"},
	]
}
