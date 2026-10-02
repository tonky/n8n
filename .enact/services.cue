package n8n

import (
	"enact.dev/schema"
	"n8n.io:enve"
)

n8n: services: enve.profiles.dev.services

// Declared kinds: enact derives connection env, probes and database forking from them.
n8n: services: {
	postgres: enact: kind: "postgres"
	redis: enact: kind:    "redis"
	cli: enact: kind:      "http"
}

pipeline: schema.#Pipeline & {
	services: n8n.services
}
