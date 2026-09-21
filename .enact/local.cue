package n8n

pipeline: {
	workflows: {
		local: {
			layout:   "topological"
			services: "on_demand"
			stages: [
				{
					name: "dev"
					tasks: ["test"]
				},
			]
		}
	}
}
