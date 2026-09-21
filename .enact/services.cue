package n8n

pipeline: {
	services: {
		postgres: {
			name:     "postgres"
			port:     5432
			database: "n8n_test"
		}
		redis: {
			name: "redis"
			port: 6379
		}
	}
}
