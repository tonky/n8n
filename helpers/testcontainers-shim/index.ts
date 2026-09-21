/**
 * Zero-Docker Testcontainers Shim for enact & enve.
 *
 * When running under enact / enve with rootless services, this shim intercepts
 * PostgreSqlContainer and RedisContainer invocations, avoiding Docker daemon startup
 * and instantly binding tests to loopback services on 127.0.0.1.
 */

export class MockStartedContainer {
  constructor(
    public host: string = '127.0.0.1',
    public port: number = 5432,
    public database: string = 'n8n_test',
  ) {}

  getHost() { return this.host; }
  getPort() { return this.port; }
  getMappedPort(_port: number) { return this.port; }
  getDatabase() { return this.database; }
  getUsername() { return 'n8n_user'; }
  getPassword() { return 'test_password'; }
  async stop() { /* no-op in rootless mode */ }
}

export class MockPostgreSqlContainer {
  private database = 'n8n_test';

  withNetwork() { return this; }
  withNetworkAliases() { return this; }
  withDatabase(db: string) { this.database = db; return this; }
  withUsername() { return this; }
  withPassword() { return this; }
  withStartupTimeout() { return this; }
  withLabels() { return this; }
  withName() { return this; }
  withReuse() { return this; }
  withLogConsumer() { return this; }

  async start(): Promise<MockStartedContainer> {
    return new MockStartedContainer('127.0.0.1', 5432, this.database);
  }
}

export class MockRedisContainer {
  withNetwork() { return this; }
  withNetworkAliases() { return this; }
  withLabels() { return this; }
  withName() { return this; }
  withReuse() { return this; }
  withLogConsumer() { return this; }

  async start(): Promise<MockStartedContainer> {
    return new MockStartedContainer('127.0.0.1', 6379);
  }
}
