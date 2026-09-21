package pkgs

import "github.com/tonky/enve/schema/v1:schema"

// -------------------------------------------------------------
// Local Developer Services, Databases & Container Tools
// -------------------------------------------------------------

postgres:       { pname: "postgresql" }
postgresql:     { pname: "postgresql" }
postgresql_18:  { pname: "postgresql", version: "18" }
postgresql_17:  { pname: "postgresql", version: "17" }
postgresql_16:  { pname: "postgresql", version: "16" }
postgresql_15:  { pname: "postgresql", version: "15" }
postgresql_14:  { pname: "postgresql", version: "14" }

redis:          { pname: "redis" }
docker_compose: { pname: "docker-compose" }
mysql:          { pname: "mysql80" }
minio:          { pname: "minio" }
mailpit:        { pname: "mailpit" }
clickhouse:     { pname: "clickhouse" }
temporal:       { pname: "temporal-cli" }
seaweedfs:      { pname: "seaweedfs" }
redpanda:       { pname: "redpanda" }
rpk:            { pname: "redpanda" }
tansu:          { pname: "tansu" }
kafka:          { pname: "tansu" }

// -------------------------------------------------------------
// High-Level Microservice & Daemon Presets (#Service presets)
// -------------------------------------------------------------

#PostgresService: schema.#Service & {
	package: schema.#PackageRef | *"postgresql"

	let defaultPort = 5432
	let defaultDataDir = ".enve/data/postgres"
	let defaultDb = "postgres"
	let defaultUser = "postgres"
	let defaultSocketDir = "/tmp"
	let defaultTimeout = "2500ms"

	port:        schema.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	socketDir:   string | *defaultSocketDir
	database:    string | *defaultDb
	user:        string | *defaultUser
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"postgres -D \(dataDir) -k \(socketDir) -p \(port)"
	lifecycle: {
		init: [
			*"initdb -D $DATA_DIR -U postgres --auth-local=trust --auth-host=trust" | string,
		]
	}
	environment: {
		PGDATA:       dataDir
		PGPORT:       "\(port)"
		PGHOST:       socketDir
		PGUSER:       user
		DATABASE_URL: "postgresql://\(user)@localhost:\(port)/\(database)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		command:   string | *"pg_isready -h 127.0.0.1 -p \(servicePort) -U \(user)"
		timeout:   schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"psql -h 127.0.0.1 -p \(servicePort) -U \(user) -d \(database) -c 'SELECT 1;'"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#RedisService: schema.#Service & {
	package: schema.#PackageRef | *"redis"

	let defaultPort = 6379
	let defaultDataDir = ".enve/data/redis"
	let defaultTimeout = "1500ms"

	port:        schema.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"redis-server --port \(port) --dir \(dataDir) --daemonize no"
	environment: {
		REDIS_PORT: "\(port)"
		REDIS_URL:  "redis://localhost:\(port)/0"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"800ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"redis-cli -p \(servicePort) ping"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#MinioService: schema.#Service & {
	package: schema.#PackageRef | *"minio"

	let defaultPort = 9000
	let defaultConsolePort = 9001
	let defaultDataDir = ".enve/data/minio"
	let defaultTimeout = "3000ms"

	port:               schema.#Port | *defaultPort
	consolePort:        schema.#Port | *defaultConsolePort
	dataDir:            string | *defaultDataDir
	timeout:            schema.#Duration | *defaultTimeout
	command:            string | *"minio server \(dataDir) --address :\(port) --console-address :\(consolePort)"
	environment: {
		MINIO_PORT:          "\(port)"
		MINIO_CONSOLE_PORT:  "\(consolePort)"
		MINIO_ROOT_USER:     "minioadmin"
		MINIO_ROOT_PASSWORD: "minioadmin"
		S3_ENDPOINT:         "http://localhost:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/live"
		timeout:   schema.#Duration | *"1500ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/minio/health/ready"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#NginxService: schema.#Service & {
	package: schema.#PackageRef | *"nginx"

	let defaultPort = 8080
	let defaultConfigFile = "/etc/nginx/nginx.conf"
	let defaultRunDir = ".enve/data/nginx"
	let defaultTimeout = "2000ms"

	port:          schema.#Port | *defaultPort
	configFile:    string | *defaultConfigFile
	runDir:        string | *defaultRunDir
	timeout:       schema.#Duration | *defaultTimeout
	command:       string | *"nginx -p \(runDir) -c \(configFile) -g 'daemon off;'"
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#MySQLService: schema.#Service & {
	package: schema.#PackageRef | *"mysql80"

	let defaultPort = 3306
	let defaultDataDir = ".enve/data/mysql"
	let defaultTimeout = "3500ms"

	port:        schema.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     schema.#Duration | *defaultTimeout
	lifecycle: {
		init: [
			*"mysqld --initialize-insecure --datadir=\"$DATA_DIR\"" | string,
		]
	}
	command:     string | *"mysqld --datadir=\(dataDir) --port=\(port)"
	environment: {
		MYSQL_TCP_PORT: "\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"1500ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"mysqladmin ping -h 127.0.0.1 -P \(servicePort)"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#ClickHouseService: schema.#Service & {
	package: schema.#PackageRef | *"clickhouse"

	let defaultHttpPort = 8123
	let defaultTcpPort = 9000
	let defaultDataDir = ".enve/data/clickhouse"
	let defaultConfigFile = ".enve/config/clickhouse/config.xml"
	let defaultTimeout = "3500ms"

	port:        schema.#Port | *defaultHttpPort
	tcpPort:     schema.#Port | *defaultTcpPort
	dataDir:     string | *defaultDataDir
	configFile:  string | *defaultConfigFile
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"clickhouse-server --config-file=\(defaultConfigFile)"
	environment: {
		CLICKHOUSE_DATA_DIR:  defaultDataDir
		CLICKHOUSE_HTTP_PORT: "\(defaultHttpPort)"
		CLICKHOUSE_TCP_PORT:  "\(defaultTcpPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		path:      string | *"http://127.0.0.1:\(servicePort)/ping"
		timeout:   schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"curl -s -f 'http://127.0.0.1:\(servicePort)/?query=SELECT+1'"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#TemporalService: schema.#Service & {
	package: schema.#PackageRef | *"temporal-cli"

	let defaultPort = 7233
	let defaultDataDir = ".enve/data/temporal"
	let defaultDbFilename = ".enve/data/temporal/temporal.db"
	let defaultTimeout = "2500ms"

	port:        schema.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	dbFilename:  string | *defaultDbFilename
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"temporal server start-dev --port \(port) --headless --db-filename \(dbFilename)"
	environment: {
		TEMPORAL_PORT: "\(port)"
		TEMPORAL_HOST: "127.0.0.1"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"1000ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"temporal operator cluster health --address 127.0.0.1:\(servicePort)"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#SeaweedfsService: schema.#Service & {
	package: schema.#PackageRef | *"seaweedfs"

	let defaultPort = 19000
	let defaultDataDir = ".enve/data/seaweedfs"
	let defaultTimeout = "6000ms"

	port:        schema.#Port | *defaultPort
	dataDir:     string | *defaultDataDir
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"weed server -s3 -s3.port=\(port) -dir=\(dataDir)"
	environment: {
		S3_PORT:     "\(port)"
		S3_ENDPOINT: "http://127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"4000ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		command:   string | *"curl -s -f -o /dev/null http://127.0.0.1:\(servicePort)/"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#RedpandaService: schema.#Service & {
	package: schema.#PackageRef | *"redpanda"

	let defaultKafkaPort = 9092
	let defaultAdminPort = 9644
	let defaultDataDir = ".enve/data/redpanda"
	let defaultTimeout = "4000ms"

	port:        schema.#Port | *defaultKafkaPort
	adminPort:   schema.#Port | *defaultAdminPort
	dataDir:     string | *defaultDataDir
	timeout:     schema.#Duration | *defaultTimeout
	command:     string | *"redpanda start --mode dev-container --kafka-addr 127.0.0.1:\(port) --admin-addr 127.0.0.1:\(adminPort) --dir \(dataDir) --smp 1 --memory 512M --reserve-memory 0M --check=false"
	environment: {
		KAFKA_PORT:     "\(port)"
		KAFKA_BROKERS:  "127.0.0.1:\(port)"
		REDPANDA_ADMIN: "127.0.0.1:\(adminPort)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"1500ms"
	}
	readinessProbe: {
		port:      schema.#Port | *adminPort
		path:      string | *"http://127.0.0.1:\(adminPort)/v1/cluster/ready"
		timeout:   schema.#Duration | *defaultTimeout
	}
}

#TansuService: schema.#Service & {
	package: schema.#PackageRef | *"tansu"

	let defaultPort = 9092
	let defaultEngine = "memory://tansu/"
	let defaultTimeout = "1500ms"

	port:          schema.#Port | *defaultPort
	storageEngine: string | *defaultEngine
	timeout:       schema.#Duration | *defaultTimeout
	command:       string | *"tansu --listener-url tcp://127.0.0.1:\(port) --advertised-listener-url tcp://127.0.0.1:\(port) --storage-engine \(storageEngine)"
	environment: {
		KAFKA_PORT:    "\(port)"
		KAFKA_BROKERS: "127.0.0.1:\(port)"
	}
	let servicePort = port
	healthCheck: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"800ms"
	}
	readinessProbe: {
		port:      schema.#Port | *servicePort
		timeout:   schema.#Duration | *"1000ms"
	}
}

#KafkaService: #TansuService

