import { vitestConfig } from '@n8n/vitest-config/frontend';
import { mergeConfig } from 'vitest/config';

import viteConfig from './vite.config.mjs';

// This file is separate from `vite.config.mts`, because `@n8n/vitest-config` resolves to its
// `dist`. Only `test` always has that `dist`, because turbo builds the dependencies before `test`.
export default mergeConfig(
	mergeConfig(viteConfig, vitestConfig),
	{
		resolve: {
			dedupe: [
				'vitest',
				'@vitest/snapshot',
				'@vitest/expect',
				'@vitest/runner',
				'@vitest/utils',
				'@vitest/spy',
				'vitest-mock-extended',
				'@testing-library/jest-dom',
				'@testing-library/vue',
				'zod',
			],
		},
		test: {
			server: {
				deps: {
					inline: [
						'vitest-mock-extended',
						'@testing-library/jest-dom',
						/@n8n\/vitest-config/,
					],
				},
			},
		},
	},
);
