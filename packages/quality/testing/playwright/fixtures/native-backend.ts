import type { N8NConfig } from 'n8n-containers/stack';
import type { ServiceHelpers } from 'n8n-containers/services/types';
import { ProxyServer } from 'n8n-containers/services/proxy';
import { resolve } from 'node:path';

/** Explicit ownership of a backend shared by Playwright workers. */
export function nativeBackendUrl(env: NodeJS.ProcessEnv = process.env): string | undefined {
	const mode = env.ENACT_PW_BACKEND;
	if (!mode) return undefined;
	if (mode !== 'shared') throw new Error(`Unsupported native Playwright backend: ${mode}`);
	const raw = env.N8N_BACKEND_URL ?? env.N8N_BASE_URL;
	if (!raw) throw new Error('Shared Playwright backend requires an explicit backend URL');
	const url = new URL(raw);
	if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
		throw new Error('Invalid shared Playwright backend URL');
	}
	return url.href.replace(/\/$/, '');
}

/** Native registration is deliberately narrower than the upstream service catalog. */
export function nativeProxyCapability(config: N8NConfig): boolean {
	return (config.services?.length ?? 0) > 0 && config.services!.every(name => name === 'proxy');
}

/** Real helper registry: absent capabilities fail instead of resembling a container. */
export async function nativeBackendServices(config: N8NConfig): Promise<ServiceHelpers> {
	const requested = config.services ?? [];
	for (const name of requested) {
		if (name !== 'proxy') throw new Error(`Unsupported native Playwright service: ${name}`);
	}
	const helpers: Partial<ServiceHelpers> = Object.create(null);
	if (requested.includes('proxy')) {
		const raw = process.env.ENACT_NATIVE_PROXY_URL;
		if (!raw) throw new Error('Native proxy capability requires ENACT_NATIVE_PROXY_URL');
		const url = new URL(raw);
		if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.username || url.password) {
			throw new Error('Native proxy requires an allocated loopback HTTP endpoint');
		}
		helpers.proxy = new ProxyServer(url.origin, resolve(__dirname, '../expectations'));
	}
	return new Proxy(helpers, {
		get(target, name) {
			if (name === 'then') return undefined;
			if (typeof name === 'string' && !Object.hasOwn(target, name)) {
				throw new Error(`Native Playwright service is not configured: ${name}`);
			}
			return Reflect.get(target, name);
		},
	}) as ServiceHelpers;
}
