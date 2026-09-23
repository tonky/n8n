package n8n

pipeline: {
	workflows: {
		local: {
			layout:   "topological"
			services: "on_demand"
			stages: {
				dev: {
					select: ["test"]
				}
			}
		}
	}
}
