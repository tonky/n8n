#!/usr/bin/env node
// Managed MockServer's public CA handoff; private keys never leave its service data.
import { X509Certificate } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const CA_ROUTE = '/__enact/mockserver-ca.pem';

function endpointUrl(endpoint) {
	const url = new URL(endpoint);
	if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port ||
		url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
		throw new Error('Native proxy requires an allocated HTTP loopback endpoint');
	}
	return url.origin;
}

export function nativeProxyEnvironment(endpoint, certificatePath) {
	const url = endpointUrl(endpoint);
	if (!isAbsolute(certificatePath)) throw new Error('Native proxy CA path must be absolute');
	return {
		HTTP_PROXY: url,
		HTTPS_PROXY: url,
		NO_PROXY: 'localhost,127.0.0.1,::1',
		NODE_EXTRA_CA_CERTS: certificatePath,
	};
}

function certificatePem(text) {
	if (Buffer.byteLength(text) > 65536 || text.includes('PRIVATE KEY') || !new X509Certificate(text).ca) {
		throw new Error('Native proxy did not provide a valid CA certificate');
	}
	return text;
}

export async function publishNativeProxyCa(endpoint, certificatePath) {
	const certificate = certificatePem(await readFile(certificatePath, 'utf8'));
	const response = await fetch(`${endpointUrl(endpoint)}/mockserver/expectation`, {
		method: 'PUT',
		signal: AbortSignal.timeout(10000),
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			priority: 100000,
			httpRequest: { method: 'GET', path: CA_ROUTE },
			httpResponse: { statusCode: 200, headers: { 'content-type': ['application/x-pem-file'] }, body: certificate },
		}),
	});
	if (!response.ok) throw new Error(`Publishing native proxy public CA failed: ${response.status}`);
}

export async function prepareNativeProxy(endpoint, directory) {
	if (!isAbsolute(directory)) throw new Error('Native proxy private directory must be absolute');
	const response = await fetch(`${endpointUrl(endpoint)}${CA_ROUTE}`, {
		signal: AbortSignal.timeout(10000),
	});
	if (!response.ok) throw new Error(`Reading native proxy public CA failed: ${response.status}`);
	const certificate = certificatePem(await response.text());
	await mkdir(directory, { recursive: true, mode: 0o700 });
	const path = join(directory, 'mockserver-ca.pem');
	await writeFile(path, certificate, { mode: 0o600, flag: 'wx' });
	return nativeProxyEnvironment(endpoint, path);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	const [command, endpoint, path] = process.argv.slice(2);
	if (command === 'publish-ca') await publishNativeProxyCa(endpoint, path);
	else if (command === 'prepare') console.log(JSON.stringify(await prepareNativeProxy(endpoint, path)));
	else throw new Error('native-proxy: expected publish-ca <endpoint> <certificate> or prepare <endpoint> <private-directory>');
}
