# Tico GitHub Pages

The published Tico site is the dependency-free static site in `tico-pages/`. GitHub Actions uploads that directory with `.github/workflows/pages.yml`; the legacy Astro source elsewhere in `site/` is not published by that workflow.

For local preview, run `python3 -m http.server 8000 --directory site/tico-pages` from the repository root and visit `http://localhost:8000/`. The page uses relative asset URLs, so it also works under the GitHub Pages `/Tico/` project path.

In the repository's **Settings → Pages**, select **GitHub Actions** as the build and deployment source. A push to `main` that changes the published directory or workflow, or a manual run of **Deploy Tico website**, then deploys the page. The workflow's deployment URL is the authoritative address.
