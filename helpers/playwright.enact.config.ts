import path from 'node:path';

import baseConfig from '../packages/quality/testing/playwright/playwright.config';

const playwrightDir = path.resolve(__dirname, '../packages/quality/testing/playwright');
const resolveFromPlaywright = (target?: string) =>
	target && target.startsWith('.') ? path.resolve(playwrightDir, target) : target;

export default {
	...baseConfig,
	testDir: resolveFromPlaywright(baseConfig.testDir) ?? playwrightDir,
	outputDir: resolveFromPlaywright(baseConfig.outputDir) ?? path.join(playwrightDir, 'test-results'),
	globalSetup:
		typeof baseConfig.globalSetup === 'string'
			? resolveFromPlaywright(baseConfig.globalSetup)
			: baseConfig.globalSetup,
	globalTeardown:
		typeof baseConfig.globalTeardown === 'string'
			? resolveFromPlaywright(baseConfig.globalTeardown)
			: baseConfig.globalTeardown,
	projects: baseConfig.projects?.map((project) => ({
		...project,
		testDir: resolveFromPlaywright(project.testDir) ?? playwrightDir,
		outputDir:
			resolveFromPlaywright(project.outputDir) ?? path.join(playwrightDir, 'test-results'),
	})),
	reporter: [['list']],
	use: {
		...baseConfig.use,
		trace: 'off' as const,
		video: 'retain-on-failure' as const,
		screenshot: 'only-on-failure' as const,
		currentsFixturesEnabled: false,
	},
};
