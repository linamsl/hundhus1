import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://www.hundhus1.se',
  output: 'static',
  integrations: [sitemap()],
});
