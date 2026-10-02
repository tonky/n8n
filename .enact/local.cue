package n8n

import "enact.dev/schema"

let J = pipeline.#jobs

pipeline: schema.#Pipeline & {
	workflows: {
		local: {
			services: "on_demand"
			stages: [{name: "dev", select: [J.test, J.smoke]}]
		}
	}
}
